output "ocr_jobs_queue_arn" {
  description = "ARN of the OCR-jobs queue (used in IAM + S3 event notification)"
  value       = aws_sqs_queue.ocr_jobs.arn
}

output "ocr_jobs_queue_url" {
  description = "URL of the OCR-jobs queue (used by SendMessage / ReceiveMessage callers)"
  value       = aws_sqs_queue.ocr_jobs.id
}

output "ocr_jobs_dlq_arn" {
  description = "ARN of the OCR-jobs DLQ (for CloudWatch alarms)"
  value       = aws_sqs_queue.ocr_jobs_dlq.arn
}

output "ocr_jobs_dlq_url" {
  description = "URL of the OCR-jobs DLQ"
  value       = aws_sqs_queue.ocr_jobs_dlq.id
}

output "extraction_jobs_queue_arn" {
  description = "ARN of the extraction-jobs queue"
  value       = aws_sqs_queue.extraction_jobs.arn
}

output "extraction_jobs_queue_url" {
  description = "URL of the extraction-jobs queue"
  value       = aws_sqs_queue.extraction_jobs.id
}

output "extraction_jobs_dlq_arn" {
  description = "ARN of the extraction-jobs DLQ (for CloudWatch alarms)"
  value       = aws_sqs_queue.extraction_jobs_dlq.arn
}

output "extraction_jobs_dlq_url" {
  description = "URL of the extraction-jobs DLQ"
  value       = aws_sqs_queue.extraction_jobs_dlq.id
}
