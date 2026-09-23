# -----------------------------------------------------------------------------
# Generic ECS service: task definition + service + log group + IAM.
#
# Each service gets its OWN execution role, allowed to read only the secrets it
# references, and its own task role. A compromised user-service task can not
# read the legacy database secret.
# -----------------------------------------------------------------------------

data "aws_region" "current" {}

locals {
  is_fargate   = var.launch == "fargate"
  network_mode = local.is_fargate ? "awsvpc" : "host"
  secret_arns  = distinct([for s in values(var.secrets) : s.secret_arn])
  volumes      = { for cpath, hpath in var.mount_points : replace(trim(cpath, "/"), "/", "-") => { container_path = cpath, host_path = hpath } }

  container = {
    name              = var.container_name
    image             = var.image
    essential         = true
    command           = var.command
    stopTimeout       = var.stop_timeout
    memory            = local.is_fargate ? null : var.memory
    memoryReservation = local.is_fargate ? null : var.memory_reservation

    portMappings = [for p in var.port_mappings : {
      containerPort = p
      hostPort      = p
      protocol      = "tcp"
    }]

    environment = [for k in sort(keys(var.environment)) : { name = k, value = var.environment[k] }]
    secrets     = [for k in sort(keys(var.secrets)) : { name = k, valueFrom = "${var.secrets[k].secret_arn}:${var.secrets[k].key}::" }]

    mountPoints = [for vname, v in local.volumes : { sourceVolume = vname, containerPath = v.container_path, readOnly = false }]

    ulimits = var.ulimits_nofile == null ? null : [{
      name      = "nofile"
      softLimit = var.ulimits_nofile
      hardLimit = var.ulimits_nofile
    }]

    healthCheck = var.health_check_command == null ? null : {
      command     = ["CMD-SHELL", var.health_check_command]
      interval    = 15
      timeout     = 5
      retries     = 4
      startPeriod = var.health_check_start_period
    }

    linuxParameters = var.enable_execute_command ? { initProcessEnabled = true } : null

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.this.name
        awslogs-region        = data.aws_region.current.region
        awslogs-stream-prefix = var.container_name
        mode                  = "non-blocking"
        max-buffer-size       = "4m"
      }
    }
  }
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

# --- IAM --------------------------------------------------------------------------
data "aws_iam_policy_document" "ecs_tasks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name                 = "${var.name}-exec"
  description          = "ECS agent for ${var.name}: pull image, write logs, read its own secrets"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

resource "aws_iam_role_policy_attachment" "execution_base" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# count keys off the (plan-time known) map keys, not the ARNs, which are
# unknown until the secrets exist.
data "aws_iam_policy_document" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = local.secret_arns
  }
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = length(var.secrets) > 0 ? 1 : 0

  name   = "read-own-secrets"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secrets[0].json
}

resource "aws_iam_role" "task" {
  name                 = "${var.name}-task"
  description          = "Runtime identity of ${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume.json
  permissions_boundary = var.permissions_boundary_arn
}

data "aws_iam_policy_document" "task_exec_command" {
  count = var.enable_execute_command ? 1 : 0

  statement {
    actions = [
      "ssmmessages:CreateControlChannel",
      "ssmmessages:CreateDataChannel",
      "ssmmessages:OpenControlChannel",
      "ssmmessages:OpenDataChannel",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "task_exec_command" {
  count = var.enable_execute_command ? 1 : 0

  name   = "ecs-exec"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task_exec_command[0].json
}

resource "aws_iam_role_policy" "task_extra" {
  count = var.task_role_policy_json == null ? 0 : 1

  name   = "application"
  role   = aws_iam_role.task.id
  policy = var.task_role_policy_json
}

# --- Task definition ----------------------------------------------------------------
resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  requires_compatibilities = [local.is_fargate ? "FARGATE" : "EC2"]
  network_mode             = local.network_mode
  cpu                      = local.is_fargate ? tostring(var.cpu) : null
  memory                   = local.is_fargate ? tostring(var.memory) : null
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  container_definitions = jsonencode([
    { for k, v in local.container : k => v if v != null }
  ])

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }

  dynamic "volume" {
    for_each = local.volumes
    content {
      name      = volume.key
      host_path = volume.value.host_path
    }
  }
}

# --- Service discovery ----------------------------------------------------------
resource "aws_service_discovery_service" "this" {
  count = var.enable_service_discovery && local.is_fargate ? 1 : 0

  name = var.container_name

  dns_config {
    namespace_id   = var.service_discovery_namespace_id
    routing_policy = "MULTIVALUE"

    dns_records {
      type = "A"
      ttl  = 10
    }
  }
}

# --- Service ------------------------------------------------------------------------
resource "aws_ecs_service" "this" {
  name                   = var.name
  cluster                = var.cluster_arn
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.desired_count
  enable_execute_command = var.enable_execute_command
  launch_type            = local.is_fargate ? null : "EC2"
  propagate_tags         = "SERVICE"

  # Host-network tasks bind fixed ports on one host: stop the old task before
  # starting the new one. Fargate tasks roll with zero downtime.
  deployment_minimum_healthy_percent = local.is_fargate ? 100 : 0
  deployment_maximum_percent         = local.is_fargate ? 200 : 100

  health_check_grace_period_seconds = var.target_port == null ? null : var.health_check_grace_period

  # On the single platform host, dependent services (Connect waits for Kafka)
  # may restart a few times on first boot; a circuit breaker would wrongly
  # mark that as a failed deployment.
  deployment_circuit_breaker {
    enable   = local.is_fargate
    rollback = local.is_fargate
  }

  dynamic "capacity_provider_strategy" {
    for_each = local.is_fargate ? [1] : []
    content {
      capacity_provider = var.fargate_capacity_provider
      weight            = 1
    }
  }

  dynamic "network_configuration" {
    for_each = local.is_fargate ? [1] : []
    content {
      subnets          = var.subnet_ids
      security_groups  = var.security_group_ids
      assign_public_ip = false
    }
  }

  dynamic "load_balancer" {
    for_each = var.target_port == null ? [] : [1] # known at plan time, unlike the ARN
    content {
      target_group_arn = var.target_group_arn
      container_name   = var.container_name
      container_port   = var.target_port
    }
  }

  dynamic "service_registries" {
    for_each = aws_service_discovery_service.this
    content {
      registry_arn = service_registries.value.arn
    }
  }

  dynamic "placement_constraints" {
    for_each = var.placement_attribute == null ? [] : [var.placement_attribute]
    content {
      type       = "memberOf"
      expression = "attribute:${placement_constraints.value.name} == ${placement_constraints.value.value}"
    }
  }
}

# --- Autoscaling (stateless HTTP only) ------------------------------------------
resource "aws_appautoscaling_target" "this" {
  count = var.autoscaling == null ? 0 : 1

  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${split("/", var.cluster_arn)[1]}/${aws_ecs_service.this.name}"
  min_capacity       = var.desired_count
  max_capacity       = var.autoscaling.max_capacity
}

resource "aws_appautoscaling_policy" "cpu" {
  count = try(var.autoscaling.cpu_target, null) == null ? 0 : 1

  name               = "${var.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  resource_id        = aws_appautoscaling_target.this[0].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling.cpu_target
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "memory" {
  count = try(var.autoscaling.memory_target, null) == null ? 0 : 1

  name               = "${var.name}-memory"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  resource_id        = aws_appautoscaling_target.this[0].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling.memory_target
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageMemoryUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "requests" {
  count = try(var.autoscaling.requests_target, null) == null ? 0 : 1

  name               = "${var.name}-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.this[0].service_namespace
  scalable_dimension = aws_appautoscaling_target.this[0].scalable_dimension
  resource_id        = aws_appautoscaling_target.this[0].resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.autoscaling.requests_target
    scale_in_cooldown  = 120
    scale_out_cooldown = 60

    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = var.autoscaling.alb_resource_label
    }
  }
}
