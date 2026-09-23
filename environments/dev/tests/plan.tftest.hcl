# Offline plan tests: `terraform test` with a mocked AWS provider.
# No credentials, no API calls, nothing is created. They prove that the
# configuration plans end to end and that the guard rails reject bad input.
#
#   cd environments/dev && terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a", "us-east-1b", "us-east-1c"] }
  }

  mock_data "aws_region" {
    defaults = { region = "us-east-1", name = "us-east-1" }
  }

  mock_data "aws_ssm_parameter" {
    defaults = { insecure_value = "ami-0123456789abcdef0", value = "ami-0123456789abcdef0" }
  }

  mock_data "aws_subnet" {
    defaults = { availability_zone = "us-east-1a" }
  }

  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  mock_data "aws_instance" {
    defaults = { instance_state = "running" }
  }
}

# On a first real plan the host does not exist yet and the check block is
# skipped with a warning; in tests it must be known to be evaluated.
override_resource {
  target          = module.messaging.aws_instance.host
  override_during = plan
  values = {
    id         = "i-0123456789abcdef0"
    private_ip = "10.20.10.10"
  }
}

variables {
  aws_region            = "us-east-1"
  allowed_ingress_cidrs = ["203.0.113.10/32"]
}

run "dev_plans_with_lab_defaults" {
  command = plan

  assert {
    condition     = module.networking.egress_mode == "nat_instance"
    error_message = "dev must use the NAT instance, not a NAT Gateway."
  }

  assert {
    condition     = module.db_legacy.logical_replication && !module.db_user.logical_replication && !module.db_sales.logical_replication
    error_message = "Only the legacy DB (Debezium source) enables logical replication."
  }

  assert {
    condition = alltrue([
      for db in [module.db_legacy, module.db_user, module.db_sales] :
      db.publicly_accessible == false && db.storage_encrypted == true
    ])
    error_message = "Databases must be private and encrypted."
  }

  assert {
    condition     = output.kafka_bootstrap_servers == "kafka.mtm-dev.internal:9092"
    error_message = "Unexpected Kafka bootstrap address."
  }

  assert {
    condition     = alltrue([for c in values(output.workload_desired_counts) : c == 0])
    error_message = "services_enabled = false must create services with 0 tasks."
  }
}

run "desired_count_change_is_visible_in_plan" {
  command = plan

  variables {
    services_enabled = true
    api_sizing = {
      "monolith-api"      = { desired_count = 3, cpu = 256, memory = 512, max_capacity = 4 }
      "user-service-api"  = { desired_count = 1, cpu = 256, memory = 512, max_capacity = 2 }
      "sales-service-api" = { desired_count = 1, cpu = 256, memory = 512, max_capacity = 2 }
    }
  }

  assert {
    condition     = output.workload_desired_counts["monolith-api"] == 3 && output.workload_desired_counts["user-service-cdc"] == 1
    error_message = "desired_count must flow from api_sizing/cdc_sizing to the ECS services."
  }
}

run "cdc_consumers_cannot_exceed_partitions" {
  command = plan

  variables {
    cdc_sizing = {
      "user-service-cdc"  = { desired_count = 2, cpu = 256, memory = 512 }
      "sales-service-cdc" = { desired_count = 1, cpu = 256, memory = 512 }
    }
  }

  expect_failures = [var.cdc_sizing]
}

run "public_ingress_requires_explicit_opt_in" {
  command = plan

  variables {
    allowed_ingress_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.allowed_ingress_cidrs]
}

run "unknown_environment_is_rejected" {
  command = plan

  variables {
    environment = "qa"
  }

  expect_failures = [var.environment]
}

run "latest_tag_is_rejected" {
  command = plan

  variables {
    image_tags = {
      "monolith-api"  = "latest"
      "user-service"  = "0.1.0"
      "sales-service" = "0.1.0"
    }
  }

  expect_failures = [var.image_tags]
}

run "invalid_fargate_size_is_rejected" {
  command = plan

  variables {
    api_sizing = {
      "monolith-api"      = { desired_count = 1, cpu = 256, memory = 4096, max_capacity = 2 }
      "user-service-api"  = { desired_count = 1, cpu = 256, memory = 512, max_capacity = 2 }
      "sales-service-api" = { desired_count = 1, cpu = 256, memory = 512, max_capacity = 2 }
    }
  }

  expect_failures = [var.api_sizing]
}
