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

# Secrets
output "rds_master_secret_arn" {
  description = "ARN of the RDS master credentials secret"
  value       = module.secrets.rds_master_secret_arn
}

output "redis_auth_token_secret_arn" {
  description = "ARN of the Redis AUTH token secret"
  value       = module.secrets.redis_auth_token_secret_arn
}

output "claude_api_key_secret_arn" {
  description = "ARN of the Claude API key secret"
  value       = module.secrets.claude_api_key_secret_arn
}

output "cohere_api_key_secret_arn" {
  description = "ARN of the Cohere API key secret"
  value       = module.secrets.cohere_api_key_secret_arn
}

output "supabase_jwt_secret_arn" {
  description = "ARN of the Supabase JWT signing secret"
  value       = module.secrets.supabase_jwt_secret_arn
}
