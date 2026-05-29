variable "environment" {
  description = "staging or prod"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the whole VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for the public subnets (one per AZ) — only the ALB and NAT live here"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for the private app subnets (one per AZ) — Fargate API + Lambda worker"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "data_subnet_cidrs" {
  description = "CIDR blocks for the private data subnets (one per AZ) — RDS + Redis, no internet route"
  type        = list(string)
  default     = ["10.0.20.0/24", "10.0.21.0/24"]
}
