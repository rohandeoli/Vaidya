terraform {
  backend "s3" {
    bucket         = "medical-ai-terraform-state-557231332919"
    key            = "prod/terraform.tfstate"
    region         = "ap-south-1"
    dynamodb_table = "medical-ai-terraform-locks"
    encrypt        = true
  }
}
