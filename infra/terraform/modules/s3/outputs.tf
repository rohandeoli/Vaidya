output "bucket_name" {
  description = "Reports bucket name — used to generate pre-signed URLs"
  value       = aws_s3_bucket.reports.id
}

output "bucket_arn" {
  description = "Reports bucket ARN — used in IAM policies"
  value       = aws_s3_bucket.reports.arn
}

output "bucket_regional_domain_name" {
  description = "Region-scoped DNS for the bucket (e.g., for direct linking)"
  value       = aws_s3_bucket.reports.bucket_regional_domain_name
}
