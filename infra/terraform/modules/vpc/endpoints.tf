data "aws_region" "current" {}

# ─────────────────────────────────────────────────────────────
# VPC endpoints — keep AWS-service traffic off the public internet.
#
# Gateway endpoint (free): S3. Wired into the private route table
# so the app tier reaches the reports bucket internally. (ECR also
# pulls image layers from S3, so Fargate needs this too.)
# ─────────────────────────────────────────────────────────────
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = {
    Name = "medical-ai-s3-endpoint-${var.environment}"
  }
}

# ─────────────────────────────────────────────────────────────
# Interface endpoints (~$7/mo each): one ENI per private subnet,
# reached over HTTPS. private_dns_enabled = true means the normal
# service hostnames (e.g. sqs.ap-south-1.amazonaws.com) resolve to
# these private IPs automatically — no app code changes needed.
#
#   sqs            - worker consume / API enqueue
#   secretsmanager - DB password, API keys
#   textract       - OCR (used by the Lambda worker)
#   ecr.api/ecr.dkr- Fargate pulls container images privately
#   logs           - CloudWatch Logs from tasks/Lambda
# ─────────────────────────────────────────────────────────────
locals {
  interface_endpoints = toset([
    "sqs",
    "secretsmanager",
    "textract",
    "ecr.api",
    "ecr.dkr",
    "logs",
  ])
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.interface_endpoints
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "medical-ai-${each.key}-endpoint-${var.environment}"
  }
}
