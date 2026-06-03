# Latest Amazon Linux 2023 ARM64 AMI, sourced from the public SSM parameter
# AWS maintains. We never pin an AMI ID — AL2023 ships security patches
# regularly and we want each rebuild to pick up the current image.
data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-arm64"
}

# ─────────────────────────────────────────────────────────────
# IAM — the bastion needs to talk to SSM (Session Manager).
# AmazonSSMManagedInstanceCore is the AWS-managed policy that
# grants exactly that, nothing more. No S3, no Secrets Manager,
# no RDS API — the bastion is a network hop, not a privileged host.
# ─────────────────────────────────────────────────────────────
resource "aws_iam_role" "bastion" {
  name = "medical-ai-bastion-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "medical-ai-bastion-${var.environment}"
  role = aws_iam_role.bastion.name
}

# ─────────────────────────────────────────────────────────────
# Security group — outbound only.
# No ingress: SSM Session Manager uses outbound HTTPS to AWS,
# there is no inbound SSH port to attack.
# Egress: HTTPS to anywhere (for SSM + package updates via NAT),
# plus TCP 5432 only to the RDS SG (for port-forwarding to Postgres).
# ─────────────────────────────────────────────────────────────
resource "aws_security_group" "bastion" {
  name        = "medical-ai-bastion-${var.environment}"
  description = "SSM-only bastion for tunneling into RDS. No ingress."
  vpc_id      = var.vpc_id

  tags = {
    Name = "medical-ai-bastion-${var.environment}"
  }
}

resource "aws_security_group_rule" "bastion_egress_https" {
  type              = "egress"
  security_group_id = aws_security_group.bastion.id
  protocol          = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_blocks       = ["0.0.0.0/0"]
  description       = "HTTPS to AWS endpoints (SSM) and package mirrors via NAT"
}

resource "aws_security_group_rule" "bastion_egress_postgres" {
  type                     = "egress"
  security_group_id        = aws_security_group.bastion.id
  protocol                 = "tcp"
  from_port                = 5432
  to_port                  = 5432
  source_security_group_id = var.rds_security_group_id
  description              = "Postgres to the RDS security group"
}

resource "aws_security_group_rule" "bastion_egress_redis" {
  type                     = "egress"
  security_group_id        = aws_security_group.bastion.id
  protocol                 = "tcp"
  from_port                = 6379
  to_port                  = 6379
  source_security_group_id = var.redis_security_group_id
  description              = "Redis to the ElastiCache security group"
}

# The matching ingress rule on the RDS SG. Lives here (not in the rds module)
# because the rds module has no concept of who its callers are — the bastion
# module is the caller, so it adds itself.
resource "aws_security_group_rule" "rds_from_bastion" {
  type                     = "ingress"
  security_group_id        = var.rds_security_group_id
  protocol                 = "tcp"
  from_port                = 5432
  to_port                  = 5432
  source_security_group_id = aws_security_group.bastion.id
  description              = "Allow Postgres from the staging bastion (SSM port forwarding)"
}

resource "aws_security_group_rule" "redis_from_bastion" {
  type                     = "ingress"
  security_group_id        = var.redis_security_group_id
  protocol                 = "tcp"
  from_port                = 6379
  to_port                  = 6379
  source_security_group_id = aws_security_group.bastion.id
  description              = "Allow Redis from the staging bastion (SSM port forwarding)"
}

# ─────────────────────────────────────────────────────────────
# The instance itself.
# ─────────────────────────────────────────────────────────────
resource "aws_instance" "bastion" {
  ami           = data.aws_ssm_parameter.al2023_arm64.value
  instance_type = var.instance_type
  subnet_id     = var.subnet_id

  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name

  # IMDSv2 only — IMDSv1 has been the vector for several SSRF-to-credential
  # exfiltration attacks. Required for any new workload in 2026.
  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  # Encrypted root volume. Default AWS-managed key is fine — no PHI on this
  # host; the OS volume just runs the SSM agent.
  root_block_device {
    encrypted   = true
    volume_type = "gp3"
    volume_size = 8
  }

  tags = {
    Name = "medical-ai-bastion-${var.environment}"
  }
}
