# KMS
output "kms_app_key_arn" {
  description = "KMS key ARN for app data (RDS, Redis, Secrets)"
  value       = module.kms.app_key_arn
}

output "kms_reports_key_arn" {
  description = "KMS key ARN for the S3 reports bucket"
  value       = module.kms.reports_key_arn
}

# VPC
output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private app subnet IDs (Fargate API, Lambda worker)"
  value       = module.vpc.private_subnet_ids
}

output "data_subnet_ids" {
  description = "Private data subnet IDs (RDS, Redis)"
  value       = module.vpc.data_subnet_ids
}

output "db_subnet_group_name" {
  description = "RDS subnet group name"
  value       = module.vpc.db_subnet_group_name
}

output "elasticache_subnet_group_name" {
  description = "ElastiCache subnet group name"
  value       = module.vpc.elasticache_subnet_group_name
}
