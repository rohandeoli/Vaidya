data "aws_caller_identity" "current" {}

module "kms" {
  source      = "../../modules/kms"
  environment = var.environment
}

module "vpc" {
  source      = "../../modules/vpc"
  environment = var.environment
}

module "secrets" {
  source      = "../../modules/secrets"
  environment = var.environment
  app_key_arn = module.kms.app_key_arn

  # Short recovery window in staging so we can iterate without
  # hitting the "name already exists" error on rapid destroy/apply.
  recovery_window_in_days = 7
}

module "s3" {
  source             = "../../modules/s3"
  environment        = var.environment
  reports_key_arn    = module.kms.reports_key_arn
  allowed_origins    = ["http://localhost:3000"]
  ocr_jobs_queue_arn = module.sqs.ocr_jobs_queue_arn

  # The bucket notification requires the SQS queue policy to be in place before
  # S3 will accept the config. Variable reference handles the queue itself; the
  # explicit depends_on covers the queue policy resource inside the sqs module.
  depends_on = [module.sqs]
}

module "sqs" {
  source             = "../../modules/sqs"
  environment        = var.environment
  app_key_arn        = module.kms.app_key_arn
  reports_bucket_arn = "arn:aws:s3:::medical-ai-reports-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

module "rds" {
  source                = "../../modules/rds"
  environment           = var.environment
  vpc_id                = module.vpc.vpc_id
  db_subnet_group_name  = module.vpc.db_subnet_group_name
  app_key_arn           = module.kms.app_key_arn
  rds_master_secret_arn = module.secrets.rds_master_secret_arn

  # Staging defaults — small, single-AZ, throwaway.
  instance_class          = "db.t4g.micro"
  multi_az                = false
  allocated_storage       = 20
  max_allocated_storage   = 100
  backup_retention_period = 1
  deletion_protection     = false
  skip_final_snapshot     = true
}

module "redis" {
  source                        = "../../modules/redis"
  environment                   = var.environment
  vpc_id                        = module.vpc.vpc_id
  elasticache_subnet_group_name = module.vpc.elasticache_subnet_group_name
  app_key_arn                   = module.kms.app_key_arn
  redis_auth_token_secret_arn   = module.secrets.redis_auth_token_secret_arn

  # Staging defaults — single node, no failover, minimal snapshot.
  node_type                  = "cache.t4g.micro"
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false
  snapshot_retention_limit   = 1
}

# Bastion is staging-only. Production access goes through the API; there is
# no human-tunnel path to the prod database or cache.
module "bastion" {
  source                  = "../../modules/bastion"
  environment             = var.environment
  vpc_id                  = module.vpc.vpc_id
  subnet_id               = module.vpc.private_subnet_ids[0]
  rds_security_group_id   = module.rds.db_security_group_id
  redis_security_group_id = module.redis.security_group_id
}
