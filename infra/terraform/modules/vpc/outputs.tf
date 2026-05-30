output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "VPC CIDR block"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet IDs (ALB, NAT)"
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private app subnet IDs (Fargate API, Lambda worker)"
  value       = aws_subnet.private[*].id
}

output "data_subnet_ids" {
  description = "Private data subnet IDs (RDS, Redis)"
  value       = aws_subnet.data[*].id
}

output "db_subnet_group_name" {
  description = "RDS subnet group name"
  value       = aws_db_subnet_group.this.name
}

output "elasticache_subnet_group_name" {
  description = "ElastiCache subnet group name"
  value       = aws_elasticache_subnet_group.this.name
}

output "alb_security_group_id" {
  description = "Security group for the ALB"
  value       = aws_security_group.alb.id
}

output "rds_security_group_id" {
  description = "Security group for RDS (ingress added by consuming modules)"
  value       = aws_security_group.rds.id
}

output "redis_security_group_id" {
  description = "Security group for Redis (ingress added by consuming modules)"
  value       = aws_security_group.redis.id
}

output "vpc_endpoints_security_group_id" {
  description = "Security group for the interface VPC endpoints"
  value       = aws_security_group.vpc_endpoints.id
}

output "s3_gateway_endpoint_id" {
  description = "S3 gateway VPC endpoint ID — used in S3 bucket policy to scope access by source VPCE"
  value       = aws_vpc_endpoint.s3.id
}

output "nat_gateway_id" {
  description = "NAT gateway ID"
  value       = aws_nat_gateway.this.id
}
