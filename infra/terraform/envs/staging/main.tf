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
