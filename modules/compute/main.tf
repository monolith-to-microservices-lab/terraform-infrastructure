# -----------------------------------------------------------------------------
# Application workloads on Fargate.
#
# HTTP services scale horizontally behind the ALB. CDC workers are NOT
# autoscaled: a consumer group can have at most one active consumer per
# partition and the lab topics have one partition (ordering per key matters).
# -----------------------------------------------------------------------------

module "http_service" {
  source   = "../ecs-service"
  for_each = var.http_services

  name                           = "${var.name}-${each.key}"
  container_name                 = each.key
  cluster_arn                    = var.cluster_arn
  launch                         = "fargate"
  fargate_capacity_provider      = var.fargate_capacity_provider
  subnet_ids                     = var.private_subnet_ids
  security_group_ids             = [each.value.security_group_id]
  image                          = each.value.image
  command                        = each.value.command
  cpu                            = each.value.cpu
  memory                         = each.value.memory
  desired_count                  = each.value.desired_count
  port_mappings                  = [each.value.container_port]
  environment                    = each.value.environment
  secrets                        = each.value.secrets
  target_group_arn               = aws_lb_target_group.http[each.key].arn
  target_port                    = each.value.container_port
  enable_service_discovery       = true
  service_discovery_namespace_id = var.namespace_id
  stop_timeout                   = 30
  permissions_boundary_arn       = var.permissions_boundary_arn
  log_retention_days             = var.log_retention_days

  health_check_command      = "python -c \"import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://localhost:${each.value.container_port}/health').status==200 else 1)\""
  health_check_start_period = 30

  autoscaling = each.value.autoscaling == null ? null : {
    max_capacity       = each.value.autoscaling.max_capacity
    cpu_target         = each.value.autoscaling.cpu_target
    memory_target      = each.value.autoscaling.memory_target
    requests_target    = each.value.autoscaling.requests_target
    alb_resource_label = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.http[each.key].arn_suffix}"
  }

  depends_on = [aws_lb_listener.http]
}

module "worker" {
  source   = "../ecs-service"
  for_each = var.workers

  name                           = "${var.name}-${each.key}"
  container_name                 = each.key
  cluster_arn                    = var.cluster_arn
  launch                         = "fargate"
  fargate_capacity_provider      = var.fargate_capacity_provider
  subnet_ids                     = var.private_subnet_ids
  security_group_ids             = [each.value.security_group_id]
  image                          = each.value.image
  command                        = each.value.command
  cpu                            = each.value.cpu
  memory                         = each.value.memory
  desired_count                  = each.value.desired_count
  environment                    = each.value.environment
  secrets                        = each.value.secrets
  enable_service_discovery       = true
  service_discovery_namespace_id = var.namespace_id
  stop_timeout                   = 30
  permissions_boundary_arn       = var.permissions_boundary_arn
  log_retention_days             = var.log_retention_days
}
