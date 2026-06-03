variable "environment" {
  description = "staging or prod"
  type        = string
}

variable "vpc_id" {
  description = "VPC the DB security group lives in"
  type        = string
}

variable "db_subnet_group_name" {
  description = "Name of the RDS subnet group (created by the vpc module). Determines which subnets the DB can be placed in — must be the data-tier subnets."
  type        = string
}

variable "app_key_arn" {
  description = "KMS key ARN used to encrypt the DB storage volume, automated backups, and snapshots."
  type        = string
}

variable "rds_master_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the master username and password (JSON: {username, password}). Read at apply time to set the DB master credentials."
  type        = string
}

variable "db_name" {
  description = "Initial database created at instance launch. The pgvector extension is created per-database, so this is the first one we'll enable it in."
  type        = string
  default     = "medical_ai"
}

variable "instance_class" {
  description = "EC2 instance class for the DB. t4g.* uses ARM Graviton — cheaper than equivalent x86. Bump for prod."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Initial gp3 storage in GB. Minimum is 20."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Ceiling for RDS storage autoscaling. Storage grows automatically up to this; stops runaway bills."
  type        = number
  default     = 100
}

variable "multi_az" {
  description = "Provision a synchronous standby in a second AZ. Roughly doubles cost. Required for any uptime SLA — prod yes, staging no."
  type        = bool
  default     = false
}

variable "backup_retention_period" {
  description = "Days of automated backups to retain. 0 disables backups (don't)."
  type        = number
  default     = 1
}

variable "backup_window" {
  description = "Daily window for automated snapshots, in UTC. Default 19:00-20:00 UTC = 00:30-01:30 IST (off-hours for the Indian audience)."
  type        = string
  default     = "19:00-20:00"
}

variable "maintenance_window" {
  description = "Weekly window for AWS-applied minor-version patches, in UTC. Default Sun 20:00-21:00 UTC = Mon 01:30-02:30 IST."
  type        = string
  default     = "Sun:20:00-Sun:21:00"
}

variable "deletion_protection" {
  description = "Refuse `terraform destroy` and AWS-console delete unless this is flipped to false first. Staging false (we want to nuke), prod true."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "When true, no snapshot is taken on destroy. Staging true, prod false."
  type        = bool
  default     = true
}
