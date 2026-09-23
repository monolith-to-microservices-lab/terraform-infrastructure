# -----------------------------------------------------------------------------
# One public ALB, one listener per HTTP service. Ports mirror the local lab
# (monolith :80 instead of :8000, user-service :8001, sales-service :8080) so the
# migration-tool and E2E suites only need a new host name.
#
# Guard rails on every listener:
#   /metrics      -> 404 (Prometheus scrapes tasks directly, never via the ALB)
#   /internal/*   -> 403 unless the caller is in internal_api_allowed_cidrs
# -----------------------------------------------------------------------------

locals {
  listener_protocol = var.certificate_arn == null ? "HTTP" : "HTTPS"
}

# Public by design; ingress is limited to allowed_ingress_cidrs by its SG.
#trivy:ignore:AWS-0053
resource "aws_lb" "this" {
  name                       = "${var.name}-alb"
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = var.public_subnet_ids
  security_groups            = [var.alb_security_group_id]
  drop_invalid_header_fields = true
  idle_timeout               = 60
  enable_deletion_protection = false
}

resource "aws_lb_target_group" "http" {
  for_each = var.http_services

  name                 = "${var.name}-${each.key}"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  protocol             = "HTTP"
  port                 = each.value.container_port
  deregistration_delay = 20 # apps drain in-flight requests in 20s

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# HTTPS is used as soon as certificate_arn is set (needs a domain + ACM cert).
#trivy:ignore:AWS-0054
resource "aws_lb_listener" "http" {
  for_each = var.http_services

  load_balancer_arn = aws_lb.this.arn
  port              = each.value.listener_port
  protocol          = local.listener_protocol
  certificate_arn   = var.certificate_arn
  ssl_policy        = var.certificate_arn == null ? null : "ELBSecurityPolicy-TLS13-1-2-2021-06"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http[each.key].arn
  }
}

resource "aws_lb_listener_rule" "block_metrics" {
  for_each = var.http_services

  listener_arn = aws_lb_listener.http[each.key].arn
  priority     = 10

  condition {
    path_pattern {
      values = ["/metrics", "/metrics/*"]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "404"
      message_body = "not found"
    }
  }
}

resource "aws_lb_listener_rule" "allow_internal" {
  for_each = length(var.internal_api_allowed_cidrs) > 0 ? var.http_services : {}

  listener_arn = aws_lb_listener.http[each.key].arn
  priority     = 20

  condition {
    path_pattern {
      values = ["/internal/*"]
    }
  }

  condition {
    source_ip {
      values = var.internal_api_allowed_cidrs
    }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.http[each.key].arn
  }
}

resource "aws_lb_listener_rule" "deny_internal" {
  for_each = var.http_services

  listener_arn = aws_lb_listener.http[each.key].arn
  priority     = 30

  condition {
    path_pattern {
      values = ["/internal/*"]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "forbidden"
    }
  }
}
