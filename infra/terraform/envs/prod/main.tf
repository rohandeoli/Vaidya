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
  # recovery_window_in_days defaults to 30 — the safety net we want in prod.
}

module "s3" {
  source          = "../../modules/s3"
  environment     = var.environment
  reports_key_arn = module.kms.reports_key_arn
  # TODO: replace with the prod web origin once the domain is registered.
  allowed_origins    = []
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
