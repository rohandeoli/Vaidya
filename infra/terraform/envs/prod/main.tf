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
  # recovery_window_in_days defaults to 30 — the safety net we want in prod.
}

module "s3" {
  source          = "../../modules/s3"
  environment     = var.environment
  reports_key_arn = module.kms.reports_key_arn
  # TODO: replace with the prod web origin once the domain is registered.
  allowed_origins = []
}

module "sqs" {
  source             = "../../modules/sqs"
  environment        = var.environment
  app_key_arn        = module.kms.app_key_arn
  reports_bucket_arn = module.s3.bucket_arn
}
