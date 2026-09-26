output "transit_gateway_id" {
  description = "Transit Gateway ID."
  value       = aws_ec2_transit_gateway.this.id
}
output "amazon_side_asn" {
  description = "Amazon-side ASN configured on the Transit Gateway."
  value       = aws_ec2_transit_gateway.this.amazon_side_asn
}
output "connect_attachment_ids" {
  description = "Transit Gateway Connect attachment IDs keyed by SLO/SLI role."
  value       = { for role, attachment in aws_ec2_transit_gateway_connect.role : role => attachment.id }
}
output "route_table_id" {
  description = "Default Transit Gateway route table used by transport and Connect attachments."
  value       = aws_ec2_transit_gateway.this.association_default_route_table_id
}
