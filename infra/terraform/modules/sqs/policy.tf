# Queue policy on ocr-jobs: allow our reports bucket (and only that bucket,
# in our account) to publish s3:ObjectCreated events as SQS messages.
# Both conditions matter — without them, any S3 bucket in any account
# could publish to this queue.

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "ocr_jobs" {
  statement {
    sid    = "AllowReportsBucketToSendMessages"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }

    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.ocr_jobs.arn]

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [var.reports_bucket_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "ocr_jobs" {
  queue_url = aws_sqs_queue.ocr_jobs.id
  policy    = data.aws_iam_policy_document.ocr_jobs.json
}
