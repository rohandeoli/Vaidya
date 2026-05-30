variable "environment" {
  description = "staging or prod"
  type        = string
}

variable "reports_key_arn" {
  description = "KMS key ARN used to encrypt every object written to this bucket. The bucket policy also denies PUTs that try to use any other KMS key."
  type        = string
}

variable "allowed_origins" {
  description = "Origins permitted to PUT directly to the bucket via pre-signed URL (browser CORS preflight). Env-specific — staging includes localhost, prod is the prod web origin only."
  type        = list(string)
}
