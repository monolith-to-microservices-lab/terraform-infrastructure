# Continuous assertions: evaluated on every plan/apply and reported as
# WARNINGS (they never block). They answer "is what exists healthy?", which
# plain drift detection does not.

check "platform_host_running" {
  data "aws_instance" "platform" {
    instance_id = module.messaging.platform_host_instance_id
  }

  assert {
    condition     = data.aws_instance.platform.instance_state == "running"
    error_message = "Platform host (Kafka/Connect) is ${data.aws_instance.platform.instance_state}: CDC is stopped and the legacy replication slot is accumulating WAL."
  }
}

check "cost_guard_nat" {
  assert {
    condition     = var.environment != "dev" || var.egress_mode == "nat_instance"
    error_message = "dev is using a NAT Gateway (~USD 33/month + USD 0.045/GB). Intentional?"
  }
}
