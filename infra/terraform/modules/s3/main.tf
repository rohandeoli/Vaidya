data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "reports" {
  bucket = "medical-ai-reports-${var.environment}-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "reports" {
  bucket = aws_s3_bucket.reports.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = var.reports_key_arn
      sse_algorithm     = "aws:kms"
    }
    # Caches a derived data key per bucket so each PUT skips a KMS API call.
    # ~99% reduction in KMS request cost; no security impact.
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_versioning" "reports" {
  bucket = aws_s3_bucket.reports.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  # Abandoned multipart uploads hold storage and are easy to leak. Clean them
  # up after a week — never relevant to keep beyond that.
  rule {
    id     = "abort-incomplete-multipart"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Noncurrent (overwritten) versions accumulate forever with versioning on.
  # Keep 30 days of recoverable history, then drop them.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "reports" {
  bucket = aws_s3_bucket.reports.id

  # Direct browser PUTs via pre-signed URL. We don't need a CORS rule for GETs —
  # pre-signed GET URLs work without CORS, and a wildcard GET rule would
  # advertise this bucket as cross-origin-readable, which is wrong for PHI.
  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "POST"]
    allowed_origins = var.allowed_origins
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# One notification config per bucket (last-write-wins). Any future destinations
# (SNS audit topic, second queue, etc.) must be added as more blocks inside
# this same resource — not as a second aws_s3_bucket_notification.
resource "aws_s3_bucket_notification" "reports" {
  bucket = aws_s3_bucket.reports.id

  queue {
    queue_arn     = var.ocr_jobs_queue_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = var.upload_prefix
  }
}
