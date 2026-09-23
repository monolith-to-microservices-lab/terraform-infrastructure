output "alb_dns_name" {
  description = "Public DNS name of the ALB."
  value       = aws_lb.this.dns_name
}

output "alb_arn_suffix" {
  description = "ALB ARN suffix (CloudWatch dimension)."
  value       = aws_lb.this.arn_suffix
}

output "endpoints" {
  description = "Public base URL per HTTP service."
  value = {
    for k, v in var.http_services :
    k => "${lower(local.listener_protocol)}://${aws_lb.this.dns_name}:${v.listener_port}"
  }
}

output "target_group_arn_suffixes" {
  description = "Target group ARN suffix per HTTP service."
  value       = { for k, tg in aws_lb_target_group.http : k => tg.arn_suffix }
}

output "service_names" {
  description = "ECS service name per workload."
  value = merge(
    { for k, m in module.http_service : k => m.service_name },
    { for k, m in module.worker : k => m.service_name },
  )
}

output "log_groups" {
  description = "CloudWatch log group per workload."
  value = merge(
    { for k, m in module.http_service : k => m.log_group_name },
    { for k, m in module.worker : k => m.log_group_name },
  )
}

output "desired_counts" {
  description = "Desired task count per workload, as planned."
  value = merge(
    { for k, v in var.http_services : k => v.desired_count },
    { for k, v in var.workers : k => v.desired_count },
  )
}
