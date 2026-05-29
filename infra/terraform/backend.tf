terraform {
  backend "s3" {
    bucket         = "medical-ai-terraform-state-557231332919"
    region         = "ap-south-1"
    dynamodb_table = "medical-ai-terraform-locks"
    encrypt        = true
    # `key` is supplied per-environment via -backend-config (see backend-*.hcl)
    # so staging and prod cannot share or clobber one state file.
  }
}
