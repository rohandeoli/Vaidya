output "app_key_arn" {
  description = "KMS key ARN for app data"
  value       = aws_kms_key.app.arn
}

output "app_key_id" {
  value = aws_kms_key.app.key_id
}

output "reports_key_arn" {
  description = "KMS key ARN for S3 reports bucket"
  value       = aws_kms_key.reports.arn
}

output "reports_key_id" {
  value = aws_kms_key.reports.key_id
}
