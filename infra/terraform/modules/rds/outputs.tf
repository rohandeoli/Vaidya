output "db_endpoint" {
  description = "Connection endpoint (host:port) — for app config and SSM tunnels."
  value       = aws_db_instance.main.endpoint
}

output "db_address" {
  description = "Hostname only (no port). Useful when port is set separately."
  value       = aws_db_instance.main.address
}

output "db_port" {
  description = "Port the DB listens on (5432)."
  value       = aws_db_instance.main.port
}

output "db_name" {
  description = "Initial database name."
  value       = aws_db_instance.main.db_name
}

output "db_instance_arn" {
  description = "Instance ARN — for IAM policies and CloudWatch alarms."
  value       = aws_db_instance.main.arn
}

output "db_security_group_id" {
  description = "RDS security group ID. The compute module attaches ingress rules to this SG."
  value       = aws_security_group.rds.id
}
