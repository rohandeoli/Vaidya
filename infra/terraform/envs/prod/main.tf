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
