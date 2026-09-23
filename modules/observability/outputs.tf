output "alarm_topic_arn" {
  description = "SNS topic receiving all alarms."
  value       = aws_sns_topic.alarms.arn
}

output "otel_collector_service_name" {
  description = "ECS service of the OTel Collector (null when disabled)."
  value       = try(module.otel_collector[0].service_name, null)
}
