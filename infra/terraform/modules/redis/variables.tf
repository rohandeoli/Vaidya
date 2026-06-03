variable "environment" {
  description = "staging or prod"
  type        = string
}

variable "vpc_id" {
  description = "VPC the Redis security group lives in."
  type        = string
}

variable "elasticache_subnet_group_name" {
  description = "Name of the ElastiCache subnet group (created by the vpc module). Must be the data-tier subnets — no internet route."
  type        = string
}

variable "app_key_arn" {
  description = "KMS key ARN used to encrypt cache data at rest and snapshots."
  type        = string
}

variable "redis_auth_token_secret_arn" {
  description = "ARN of the Secrets Manager secret holding the Redis AUTH token. Plain-string secret (no JSON wrapping). Read at apply time."
  type        = string
}

variable "node_type" {
  description = "ElastiCache node instance class. cache.t4g.* uses ARM Graviton."
  type        = string
  default     = "cache.t4g.micro"
}

variable "num_cache_clusters" {
  description = "Total nodes in the replication group (primary + replicas). 1 = primary only (staging), 2 = primary + 1 replica (prod minimum for failover)."
  type        = number
  default     = 1
}

variable "automatic_failover_enabled" {
  description = "Promote a replica to primary on primary failure. Requires num_cache_clusters >= 2."
  type        = bool
  default     = false
}

variable "multi_az_enabled" {
  description = "Place replicas in a different AZ from the primary. Requires automatic_failover_enabled = true."
  type        = bool
  default     = false
}

variable "engine_version" {
  description = "Redis engine version. ElastiCache supports 7.x — pick the latest stable."
  type        = string
  default     = "7.1"
}

variable "snapshot_retention_limit" {
  description = "Days of RDB snapshots to keep. Set to 0 to disable snapshots entirely. Even though we hold no PHI, 1 day gives us a rollback for accidental FLUSHDB."
  type        = number
  default     = 1
}

variable "snapshot_window" {
  description = "Daily window when snapshots are taken (UTC). 03:00-04:00 UTC = 08:30-09:30 IST. Off-hours for our audience."
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  description = "Weekly window for AWS-applied minor-version patches (UTC). Sun 20:00-21:00 UTC = Mon 01:30-02:30 IST."
  type        = string
  default     = "Sun:20:00-Sun:21:00"
}
