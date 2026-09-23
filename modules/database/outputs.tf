output "instance_id" {
  description = "RDS instance identifier."
  value       = aws_db_instance.this.identifier
}

output "address" {
  description = "Endpoint hostname."
  value       = aws_db_instance.this.address
}

output "port" {
  description = "Endpoint port."
  value       = aws_db_instance.this.port
}

output "db_name" {
  description = "Database name."
  value       = var.db_name
}

output "security_group_id" {
  description = "Security group attached to the instance."
  value       = aws_security_group.this.id
}

output "secret_arn" {
  description = "Secrets Manager ARN with host/port/dbname/username/password/database_url."
  value       = aws_secretsmanager_secret.this.arn
}

output "logical_replication" {
  description = "Whether logical decoding (Debezium source) is enabled."
  value       = var.logical_replication
}

output "publicly_accessible" {
  description = "Must always be false."
  value       = aws_db_instance.this.publicly_accessible
}

output "storage_encrypted" {
  description = "Must always be true."
  value       = aws_db_instance.this.storage_encrypted
}
