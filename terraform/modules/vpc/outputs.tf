output "vpc_id" { value = aws_vpc.this.id }
output "public_subnet_id" { value = aws_subnet.public.id }
output "private_subnet_id" { value = aws_subnet.private.id }
output "internet_gateway_id" { value = aws_internet_gateway.this.id }
output "public_route_table_id" { value = aws_route_table.public.id }
output "private_route_table_id" { value = aws_route_table.private.id }
output "nat_gateway_public_ip" { value = one(aws_eip.nat[*].public_ip) }
output "interface_endpoint_ids" { value = { for k, v in aws_vpc_endpoint.interface : k => v.id } }
output "s3_vpc_endpoint_id" { value = aws_vpc_endpoint.s3.id }
