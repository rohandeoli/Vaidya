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

output "s3_gateway_endpoint_id" {
  description = "S3 gateway VPC endpoint ID (consumed by the s3 module's bucket policy)"
  value       = module.vpc.s3_gateway_endpoint_id
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

# S3
output "reports_bucket_name" {
  description = "Reports bucket name"
  value       = module.s3.bucket_name
}

output "reports_bucket_arn" {
  description = "Reports bucket ARN"
  value       = module.s3.bucket_arn
}

# SQS
output "ocr_jobs_queue_arn" {
  description = "OCR-jobs queue ARN"
  value       = module.sqs.ocr_jobs_queue_arn
}

output "ocr_jobs_queue_url" {
  description = "OCR-jobs queue URL"
  value       = module.sqs.ocr_jobs_queue_url
}

output "ocr_jobs_dlq_arn" {
  description = "OCR-jobs DLQ ARN"
  value       = module.sqs.ocr_jobs_dlq_arn
}

output "extraction_jobs_queue_arn" {
  description = "Extraction-jobs queue ARN"
  value       = module.sqs.extraction_jobs_queue_arn
}

output "extraction_jobs_queue_url" {
  description = "Extraction-jobs queue URL"
  value       = module.sqs.extraction_jobs_queue_url
}

output "extraction_jobs_dlq_arn" {
  description = "Extraction-jobs DLQ ARN"
  value       = module.sqs.extraction_jobs_dlq_arn
}

# RDS
output "db_endpoint" {
  description = "RDS connection endpoint (host:port) — feed into app config and SSM tunnels"
  value       = module.rds.db_endpoint
}

output "db_address" {
  description = "RDS hostname (no port)"
  value       = module.rds.db_address
}

output "db_port" {
  description = "RDS port"
  value       = module.rds.db_port
}

output "db_name" {
  description = "Initial database name"
  value       = module.rds.db_name
}

output "db_instance_arn" {
  description = "RDS instance ARN"
  value       = module.rds.db_instance_arn
}

output "db_security_group_id" {
  description = "RDS security group ID (compute module attaches ingress rules here)"
  value       = module.rds.db_security_group_id
}
