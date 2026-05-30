variable "environment" {
  description = "staging or prod"
  type        = string
}

variable "app_key_arn" {
  description = "KMS key ARN used to encrypt every secret in this module"
  type        = string
}

variable "recovery_window_in_days" {
  description = "Days a deleted secret stays recoverable before AWS hard-deletes it (0, or 7–30). 7 is convenient in staging; keep 30 in prod."
  type        = number
  default     = 30
}
