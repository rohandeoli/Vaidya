# Terraform-generated values (RDS master, Redis auth token).
# Container + version live under the same TF address pair.

resource "aws_secretsmanager_secret" "rds_master" {
  name                    = "medical-ai/${var.environment}/rds/master"
  description             = "Postgres master credentials (JSON: username, password)"
  kms_key_id              = var.app_key_arn
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "rds_master" {
  secret_id = aws_secretsmanager_secret.rds_master.id
  secret_string = jsonencode({
    username = "vaidya_admin"
    password = random_password.rds_master.result
  })
}

resource "aws_secretsmanager_secret" "redis_auth_token" {
  name                    = "medical-ai/${var.environment}/redis/auth-token"
  description             = "ElastiCache Redis AUTH token"
  kms_key_id              = var.app_key_arn
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret_version" "redis_auth_token" {
  secret_id     = aws_secretsmanager_secret.redis_auth_token.id
  secret_string = random_password.redis_auth_token.result
}

# Human-populated values. We provision the empty container; an operator pastes
# the value into the AWS console (or via CLI) once. No _secret_version resource
# here — Terraform must never own these values.

resource "aws_secretsmanager_secret" "claude_api_key" {
  name                    = "medical-ai/${var.environment}/claude/api-key"
  description             = "Anthropic Claude API key — populated manually"
  kms_key_id              = var.app_key_arn
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret" "cohere_api_key" {
  name                    = "medical-ai/${var.environment}/cohere/api-key"
  description             = "Cohere embeddings API key — populated manually"
  kms_key_id              = var.app_key_arn
  recovery_window_in_days = var.recovery_window_in_days
}

resource "aws_secretsmanager_secret" "supabase_jwt_secret" {
  name                    = "medical-ai/${var.environment}/supabase/jwt-secret"
  description             = "Supabase JWT signing secret — populated manually"
  kms_key_id              = var.app_key_arn
  recovery_window_in_days = var.recovery_window_in_days
}
