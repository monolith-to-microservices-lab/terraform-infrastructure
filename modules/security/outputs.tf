output "alb_security_group_id" {
  description = "Security group of the public ALB."
  value       = aws_security_group.alb.id
}

output "workload_security_group_ids" {
  description = "Security group per workload name."
  value       = { for k, sg in aws_security_group.workload : k => sg.id }
}

output "platform_security_group_id" {
  description = "Security group of the platform host."
  value       = aws_security_group.platform.id
}
