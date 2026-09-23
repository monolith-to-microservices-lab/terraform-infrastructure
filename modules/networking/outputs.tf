output "vpc_id" {
  description = "VPC ID."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block."
  value       = aws_vpc.this.cidr_block
}

output "azs" {
  description = "Availability zones in use."
  value       = local.azs
}

output "public_subnet_ids" {
  description = "Public subnets (ALB, NAT)."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnets with NAT egress (ECS tasks, platform host)."
  value       = aws_subnet.private[*].id
}

output "data_subnet_ids" {
  description = "Isolated subnets without internet route (RDS)."
  value       = aws_subnet.data[*].id
}

output "nat_public_ip" {
  description = "Public egress IP of the NAT (useful for allow-lists)."
  value       = local.use_nat_gateway ? aws_eip.nat[0].public_ip : aws_instance.nat[0].public_ip
}

output "egress_mode" {
  description = "nat_instance or nat_gateway."
  value       = var.egress_mode
}
