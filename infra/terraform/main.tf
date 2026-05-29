module "kms" {
  source      = "./modules/kms"
  environment = var.environment
}

module "vpc" {
  source      = "./modules/vpc"
  environment = var.environment
}
