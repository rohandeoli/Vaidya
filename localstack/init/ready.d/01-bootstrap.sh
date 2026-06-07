#!/bin/bash
# LocalStack auto-runs every executable script in /etc/localstack/init/ready.d/
# once the gateway is ready. This creates the S3 bucket + SQS queues so the
# app doesn't need to bootstrap AWS state on first boot.
#
# Mirrors prod naming from infra/terraform/modules/{s3,sqs} with env=local.
# `awslocal` is preinstalled in the localstack image and routes to localhost.

set -euo pipefail

REGION="${DEFAULT_REGION:-ap-south-1}"
BUCKET="medical-ai-reports-local"
OCR_QUEUE="medical-ai-ocr-jobs-local"
OCR_DLQ="medical-ai-ocr-jobs-local-dlq"
EXTRACTION_QUEUE="medical-ai-extraction-jobs-local"
EXTRACTION_DLQ="medical-ai-extraction-jobs-local-dlq"

echo "→ Creating S3 bucket: $BUCKET"
awslocal s3api create-bucket \
  --bucket "$BUCKET" \
  --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

echo "→ Creating SQS DLQs"
awslocal sqs create-queue --queue-name "$OCR_DLQ"
awslocal sqs create-queue --queue-name "$EXTRACTION_DLQ"

OCR_DLQ_ARN=$(awslocal sqs get-queue-attributes \
  --queue-url "http://localhost:4566/000000000000/${OCR_DLQ}" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

EXTRACTION_DLQ_ARN=$(awslocal sqs get-queue-attributes \
  --queue-url "http://localhost:4566/000000000000/${EXTRACTION_DLQ}" \
  --attribute-names QueueArn --query 'Attributes.QueueArn' --output text)

echo "→ Creating SQS main queues with DLQ redrive"
awslocal sqs create-queue --queue-name "$OCR_QUEUE" --attributes "{
  \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"${OCR_DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\",
  \"VisibilityTimeout\": \"120\"
}"

awslocal sqs create-queue --queue-name "$EXTRACTION_QUEUE" --attributes "{
  \"RedrivePolicy\": \"{\\\"deadLetterTargetArn\\\":\\\"${EXTRACTION_DLQ_ARN}\\\",\\\"maxReceiveCount\\\":\\\"3\\\"}\",
  \"VisibilityTimeout\": \"60\"
}"

echo "✓ LocalStack bootstrap complete"
