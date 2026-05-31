variable "environment" {
  description = "staging or prod"
  type        = string
}

variable "app_key_arn" {
  description = "KMS key ARN used for server-side encryption of every queue."
  type        = string
}

variable "reports_bucket_arn" {
  description = "ARN of the reports S3 bucket — scoped into the ocr-jobs queue policy so only that bucket (in our account) can publish events."
  type        = string
}
