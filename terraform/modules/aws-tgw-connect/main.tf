locals {
  roles = toset(["slo", "sli"])
  tags = merge(var.ownership_tags, {
    Name      = "${var.name_prefix}-tgw"
    ManagedBy = "terraform"
  })
}
resource "aws_ec2_transit_gateway" "this" {
  amazon_side_asn                 = var.amazon_side_asn
  auto_accept_shared_attachments  = "disable"
  default_route_table_association = "enable"
  default_route_table_propagation = "disable"
  dns_support                     = "enable"
  transit_gateway_cidr_blocks     = [var.transit_gateway_cidr_block]
  vpn_ecmp_support                = "enable"
  tags                            = local.tags
}
resource "aws_ec2_transit_gateway_vpc_attachment" "transport" {
  subnet_ids                                      = var.transport_subnet_ids
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  transit_gateway_default_route_table_association = true
  transit_gateway_default_route_table_propagation = false
  vpc_id                                          = var.vpc_id
  tags                                            = merge(local.tags, { Name = "${var.name_prefix}-tgw-transport" })
}
resource "aws_ec2_transit_gateway_route_table_propagation" "transport" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.transport.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this.association_default_route_table_id
}
resource "aws_ec2_transit_gateway_connect" "role" {
  for_each                                        = local.roles
  protocol                                        = "gre"
  transit_gateway_default_route_table_association = true
  transit_gateway_default_route_table_propagation = false
  transit_gateway_id                              = aws_ec2_transit_gateway.this.id
  transport_attachment_id                         = aws_ec2_transit_gateway_vpc_attachment.transport.id
  tags                                            = merge(local.tags, { Name = "${var.name_prefix}-tgw-connect-${each.key}" })
}
resource "aws_ec2_transit_gateway_route_table_propagation" "connect" {
  for_each                       = aws_ec2_transit_gateway_connect.role
  transit_gateway_attachment_id  = each.value.id
  transit_gateway_route_table_id = aws_ec2_transit_gateway.this.association_default_route_table_id
}
