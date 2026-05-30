# Bucket policy — defense in depth on top of IAM. Each statement is a deny,
# so a misconfigured caller (or a leaked credential with overly broad IAM)
# still can't violate the contract.
#
# NOT included yet: an `aws:sourceVpce` restriction. That breaks the planned
# direct-browser-upload flow (pre-signed PUTs come from the user's network,
# not our VPC). Revisit once the API is wired up and we know the real access
# patterns — likely a scoped policy that requires VPCE for everything except
# PutObject/GetObject.

data "aws_iam_policy_document" "reports" {
  # 1. Block any request that isn't over HTTPS.
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.reports.arn,
      "${aws_s3_bucket.reports.arn}/*",
    ]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # 2. Block PUTs that aren't using SSE-KMS. Even if the default encryption
  # config is somehow disabled, this rejects the upload at the perimeter.
  statement {
    sid    = "DenyUnencryptedPuts"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/*"]
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }

  # 3. Block PUTs that try to use any KMS key other than our reports key.
  # Prevents an attacker from uploading data encrypted with a key they
  # control (which they could later decrypt themselves).
  statement {
    sid    = "DenyWrongKmsKey"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.reports.arn}/*"]
    condition {
      test     = "StringNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.reports_key_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "reports" {
  bucket = aws_s3_bucket.reports.id
  policy = data.aws_iam_policy_document.reports.json

  # The public access block must be evaluated first; otherwise applying any
  # bucket policy can flap on a freshly-created bucket.
  depends_on = [aws_s3_bucket_public_access_block.reports]
}
