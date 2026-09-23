output "kafka_bootstrap_servers" {
  description = "Kafka bootstrap address for clients inside the VPC."
  value       = "${local.kafka_host}:${local.kafka_port}"
}

output "connect_url" {
  description = "Kafka Connect REST URL (reachable only from the host; use SSM port forwarding)."
  value       = "http://${local.connect_host}:8083"
}

output "platform_host_instance_id" {
  description = "EC2 instance id of the platform host (SSM target)."
  value       = aws_instance.host.id
}

output "platform_host_private_ip" {
  description = "Private IP of the platform host."
  value       = aws_instance.host.private_ip
}

output "placement_attribute" {
  description = "ECS attribute that pins tasks to the platform host."
  value       = var.placement_attribute
}

output "data_volume_id" {
  description = "Persistent EBS volume with Kafka data."
  value       = aws_ebs_volume.data.id
}

output "debezium_secret_arn" {
  description = "Secret with the Debezium replication user credentials."
  value       = aws_secretsmanager_secret.debezium.arn
}

output "service_names" {
  description = "ECS service names."
  value       = { kafka = module.kafka.service_name, connect = module.connect.service_name }
}
