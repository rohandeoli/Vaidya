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

variable "ocr_jobs_queue_arn" {
  description = "ARN of the SQS queue that receives ObjectCreated events for uploaded reports. The SQS queue policy must already grant s3.amazonaws.com SendMessage on this ARN (set up in the sqs module)."
  type        = string
}

variable "upload_prefix" {
  description = "Object key prefix that triggers the OCR pipeline. Pre-signed URLs should place uploads under this prefix; objects outside it (generated reports, exports) are not sent to OCR."
  type        = string
  default     = "uploads/"
}
