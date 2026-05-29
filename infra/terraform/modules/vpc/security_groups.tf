# ─────────────────────────────────────────────────────────────
# Security groups (stateful firewalls).
#
# This module owns the edge + data-tier SGs. The compute SGs
# (Fargate API, Lambda worker) are defined in their own modules,
# which will ALSO attach the ingress rules that open RDS/Redis to
# them — referencing the SG IDs exported from here. That keeps the
# data SGs free of forward references to resources that don't
# exist yet, and avoids a dependency cycle.
# ─────────────────────────────────────────────────────────────

# ALB — the only internet-facing resource.
resource "aws_security_group" "alb" {
  name        = "medical-ai-alb-${var.environment}"
  description = "ALB - public HTTPS ingress"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "medical-ai-alb-${var.environment}"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# ALB egress stays open; the restriction that only the ALB may
# reach the API is enforced on the API SG's INBOUND side.
resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Interface VPC endpoints — answer HTTPS from clients inside the VPC.
resource "aws_security_group" "vpc_endpoints" {
  name        = "medical-ai-vpce-${var.environment}"
  description = "Interface VPC endpoints - HTTPS from within the VPC"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "medical-ai-vpce-${var.environment}"
  }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_https" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "HTTPS from within the VPC"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = var.vpc_cidr
}

resource "aws_vpc_security_group_egress_rule" "vpce_all" {
  security_group_id = aws_security_group.vpc_endpoints.id
  description       = "Allow all outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# RDS — sealed shut by default. The 5432 ingress from the Fargate
# API SG and Lambda worker SG is added by those modules. No egress
# rule = no outbound, which is correct for a database.
resource "aws_security_group" "rds" {
  name        = "medical-ai-rds-${var.environment}"
  description = "RDS Postgres - ingress from app tier only (rules added by consuming modules)"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "medical-ai-rds-${var.environment}"
  }
}

# Redis — same posture as RDS; 6379 ingress added by the API module.
resource "aws_security_group" "redis" {
  name        = "medical-ai-redis-${var.environment}"
  description = "ElastiCache Redis - ingress from app tier only (rules added by consuming modules)"
  vpc_id      = aws_vpc.this.id

  tags = {
    Name = "medical-ai-redis-${var.environment}"
  }
}
