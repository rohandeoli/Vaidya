# Dead-letter queues live first — the main queues reference their ARNs.
# DLQs are themselves regular SQS queues with no redrive policy (terminal).
# Longer retention (14d) gives humans time to investigate before SQS expires.

resource "aws_sqs_queue" "ocr_jobs_dlq" {
  name                      = "medical-ai-ocr-jobs-${var.environment}-dlq"
  message_retention_seconds = 1209600 # 14 days
  receive_wait_time_seconds = 20
  kms_master_key_id         = var.app_key_arn
}

resource "aws_sqs_queue" "extraction_jobs_dlq" {
  name                      = "medical-ai-extraction-jobs-${var.environment}-dlq"
  message_retention_seconds = 1209600 # 14 days
  receive_wait_time_seconds = 20
  kms_master_key_id         = var.app_key_arn
}

# Main queues — visibility timeout sized for the worst-case downstream work
# (Textract OCR can take ~90s on multipage PDFs; extraction parsing is faster).
# Rule of thumb: visibility >= 6x expected processing time, and >= the consumer
# Lambda's timeout.

resource "aws_sqs_queue" "ocr_jobs" {
  name                       = "medical-ai-ocr-jobs-${var.environment}"
  visibility_timeout_seconds = 120
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 20
  kms_master_key_id          = var.app_key_arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ocr_jobs_dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue" "extraction_jobs" {
  name                       = "medical-ai-extraction-jobs-${var.environment}"
  visibility_timeout_seconds = 60
  message_retention_seconds  = 345600 # 4 days
  receive_wait_time_seconds  = 20
  kms_master_key_id          = var.app_key_arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.extraction_jobs_dlq.arn
    maxReceiveCount     = 5
  })
}
