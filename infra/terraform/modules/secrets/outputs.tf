output "rds_master_secret_arn" {
  description = "ARN of the RDS master credentials secret (JSON: username, password)"
  value       = aws_secretsmanager_secret.rds_master.arn
}

output "redis_auth_token_secret_arn" {
  description = "ARN of the Redis AUTH token secret"
  value       = aws_secretsmanager_secret.redis_auth_token.arn
}

output "claude_api_key_secret_arn" {
  description = "ARN of the Claude API key secret (value populated manually)"
  value       = aws_secretsmanager_secret.claude_api_key.arn
}

output "cohere_api_key_secret_arn" {
  description = "ARN of the Cohere API key secret (value populated manually)"
  value       = aws_secretsmanager_secret.cohere_api_key.arn
}

output "supabase_jwt_secret_arn" {
  description = "ARN of the Supabase JWT signing secret (value populated manually)"
  value       = aws_secretsmanager_secret.supabase_jwt_secret.arn
}
