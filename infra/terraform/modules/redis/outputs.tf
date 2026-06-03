output "primary_endpoint_address" {
  description = "Hostname for writes. All writes from the API + worker go here."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "reader_endpoint_address" {
  description = "Hostname for reads. Round-robins across replicas in prod; same as primary in staging (single node)."
  value       = aws_elasticache_replication_group.main.reader_endpoint_address
}

output "port" {
  description = "Redis port (6379)."
  value       = aws_elasticache_replication_group.main.port
}

output "replication_group_arn" {
  description = "Replication group ARN — for CloudWatch alarms and IAM policies."
  value       = aws_elasticache_replication_group.main.arn
}

output "security_group_id" {
  description = "Redis security group ID. Compute and bastion add ingress rules here."
  value       = aws_security_group.redis.id
}
