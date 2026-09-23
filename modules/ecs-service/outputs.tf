output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.this.name
}

output "service_id" {
  description = "ECS service ARN."
  value       = aws_ecs_service.this.id
}

output "task_definition_arn" {
  description = "Current task definition revision."
  value       = aws_ecs_task_definition.this.arn
}

output "log_group_name" {
  description = "CloudWatch log group."
  value       = aws_cloudwatch_log_group.this.name
}

output "task_role_arn" {
  description = "Runtime IAM role."
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "ECS execution IAM role."
  value       = aws_iam_role.execution.arn
}

output "discovery_name" {
  description = "Cloud Map service name (null when not registered)."
  value       = try(aws_service_discovery_service.this[0].name, null)
}
