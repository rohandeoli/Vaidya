variable "environment" {
  description = "staging or prod. Bastion is intended for staging only — prod access goes through the API."
  type        = string
}

variable "vpc_id" {
  description = "VPC the bastion lives in."
  type        = string
}

variable "subnet_id" {
  description = "Private app subnet (NOT data subnet). The bastion needs an outbound path to SSM endpoints — private subnets route 0.0.0.0/0 via NAT; data subnets are fully isolated."
  type        = string
}

variable "rds_security_group_id" {
  description = "RDS security group ID. The bastion module attaches an ingress rule to this SG allowing TCP 5432 from the bastion's own SG."
  type        = string
}

variable "redis_security_group_id" {
  description = "Redis security group ID. The bastion module attaches an ingress rule to this SG allowing TCP 6379 from the bastion's own SG."
  type        = string
}

variable "instance_type" {
  description = "EC2 instance type. t4g.nano (ARM, ~$3/mo) is plenty — the bastion forwards bytes, it doesn't compute."
  type        = string
  default     = "t4g.nano"
}
