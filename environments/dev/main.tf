# -----------------------------------------------------------------------------
# dev environment: composition only. Every resource lives in a module.
# Architecture: docs/aws-architecture.md
# -----------------------------------------------------------------------------

module "networking" {
  source = "../../modules/networking"

  name                     = local.name
  vpc_cidr                 = var.vpc_cidr
  az_count                 = var.az_count
  egress_mode              = var.egress_mode
  enable_flow_logs         = var.enable_flow_logs
  permissions_boundary_arn = var.permissions_boundary_arn
}

module "security" {
  source = "../../modules/security"

  name                  = local.name
  vpc_id                = module.networking.vpc_id
  vpc_cidr              = module.networking.vpc_cidr
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  alb_listener_ports    = [for w in values(local.http_workloads) : w.listener_port]
  http_workloads        = { for k, w in local.http_workloads : k => { port = w.port } }
  worker_workloads      = local.worker_workloads
}

module "registry" {
  source = "../../modules/registry"

  name_prefix  = var.name_prefix
  repositories = ["monolith-api", "user-service", "sales-service"]
}

# --- Databases ------------------------------------------------------------------------
module "db_legacy" {
  source = "../../modules/database"

  name                  = "${local.name}-legacy-pg"
  secret_name           = "${var.name_prefix}/${var.environment}/legacy-db"
  vpc_id                = module.networking.vpc_id
  subnet_ids            = module.networking.data_subnet_ids
  db_name               = "monolith"
  username              = "postgres"
  sqlalchemy_driver     = "postgresql+psycopg"
  instance_class        = var.db_instance_class
  deletion_protection   = var.db_deletion_protection
  backup_retention_days = var.db_backup_retention_days
  password_version      = var.db_password_version

  # Debezium source: wal_level=logical equivalent + WAL retention cap.
  logical_replication = true

  allowed_security_group_ids = {
    "monolith-api"             = module.security.workload_security_group_ids["monolith-api"]
    "platform-host (debezium)" = module.security.platform_security_group_id
  }
}

module "db_user" {
  source = "../../modules/database"

  name                  = "${local.name}-user-pg"
  secret_name           = "${var.name_prefix}/${var.environment}/user-db"
  vpc_id                = module.networking.vpc_id
  subnet_ids            = module.networking.data_subnet_ids
  db_name               = "user_service"
  username              = "user_service"
  sqlalchemy_driver     = "postgresql+psycopg"
  instance_class        = var.db_instance_class
  deletion_protection   = var.db_deletion_protection
  backup_retention_days = var.db_backup_retention_days
  password_version      = var.db_password_version

  allowed_security_group_ids = {
    "user-service-api" = module.security.workload_security_group_ids["user-service-api"]
    "user-service-cdc" = module.security.workload_security_group_ids["user-service-cdc"]
  }
}

module "db_sales" {
  source = "../../modules/database"

  name                  = "${local.name}-sales-pg"
  secret_name           = "${var.name_prefix}/${var.environment}/sales-db"
  vpc_id                = module.networking.vpc_id
  subnet_ids            = module.networking.data_subnet_ids
  db_name               = "sales"
  username              = "sales"
  sqlalchemy_driver     = "postgresql+psycopg2" # sales-service uses psycopg2
  instance_class        = var.db_instance_class
  deletion_protection   = var.db_deletion_protection
  backup_retention_days = var.db_backup_retention_days
  password_version      = var.db_password_version

  allowed_security_group_ids = {
    "sales-service-api" = module.security.workload_security_group_ids["sales-service-api"]
    "sales-service-cdc" = module.security.workload_security_group_ids["sales-service-cdc"]
  }
}

# --- Container platform -----------------------------------------------------------------
module "ecs_cluster" {
  source = "../../modules/ecs-cluster"

  name               = local.name
  vpc_id             = module.networking.vpc_id
  namespace          = local.namespace
  container_insights = var.container_insights
}

module "messaging" {
  source = "../../modules/messaging"

  name                      = local.name
  name_prefix               = var.name_prefix
  environment               = var.environment
  cluster_name              = module.ecs_cluster.cluster_name
  cluster_arn               = module.ecs_cluster.cluster_arn
  namespace_id              = module.ecs_cluster.namespace_id
  namespace_name            = module.ecs_cluster.namespace_name
  subnet_id                 = module.networking.private_subnet_ids[0]
  security_group_id         = module.security.platform_security_group_id
  instance_type             = var.platform_instance_type
  data_volume_size_gb       = var.platform_data_volume_gb
  placement_attribute       = local.platform_attribute
  extra_dns_names           = var.enable_otel_collector ? ["otel-collector"] : []
  kafka_cluster_id          = var.kafka_cluster_id
  kafka_default_partitions  = var.kafka_default_partitions
  legacy_db_address         = module.db_legacy.address
  legacy_db_name            = module.db_legacy.db_name
  debezium_password_version = var.debezium_password_version
  permissions_boundary_arn  = var.permissions_boundary_arn
  log_retention_days        = var.log_retention_days
  alarm_topic_arn           = module.observability.alarm_topic_arn
}

module "compute" {
  source = "../../modules/compute"

  name                       = local.name
  vpc_id                     = module.networking.vpc_id
  public_subnet_ids          = module.networking.public_subnet_ids
  private_subnet_ids         = module.networking.private_subnet_ids
  alb_security_group_id      = module.security.alb_security_group_id
  cluster_arn                = module.ecs_cluster.cluster_arn
  namespace_id               = module.ecs_cluster.namespace_id
  certificate_arn            = var.certificate_arn
  internal_api_allowed_cidrs = var.internal_api_allowed_cidrs
  fargate_capacity_provider  = var.fargate_capacity_provider
  permissions_boundary_arn   = var.permissions_boundary_arn
  log_retention_days         = var.log_retention_days

  http_services = {
    "monolith-api" = {
      listener_port     = local.http_workloads["monolith-api"].listener_port
      container_port    = local.http_workloads["monolith-api"].port
      image             = local.images["monolith-api"]
      cpu               = var.api_sizing["monolith-api"].cpu
      memory            = var.api_sizing["monolith-api"].memory
      desired_count     = local.desired["monolith-api"]
      security_group_id = module.security.workload_security_group_ids["monolith-api"]
      environment = {
        CORS_ORIGINS                = var.monolith_cors_origins
        OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_endpoint
      }
      secrets = {
        DATABASE_URL = { secret_arn = module.db_legacy.secret_arn, key = "database_url" }
      }
      autoscaling = {
        max_capacity    = var.api_sizing["monolith-api"].max_capacity
        cpu_target      = 60
        requests_target = 500
      }
    }

    "user-service-api" = {
      listener_port     = local.http_workloads["user-service-api"].listener_port
      container_port    = local.http_workloads["user-service-api"].port
      image             = local.images["user-service"]
      cpu               = var.api_sizing["user-service-api"].cpu
      memory            = var.api_sizing["user-service-api"].memory
      desired_count     = local.desired["user-service-api"]
      security_group_id = module.security.workload_security_group_ids["user-service-api"]
      environment = {
        APP_ENV                     = "development"
        LOG_LEVEL                   = "INFO"
        GRACEFUL_SHUTDOWN_SECONDS   = "20"
        OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_endpoint
      }
      secrets = {
        DATABASE_URL = { secret_arn = module.db_user.secret_arn, key = "database_url" }
      }
      autoscaling = {
        max_capacity    = var.api_sizing["user-service-api"].max_capacity
        cpu_target      = 60
        requests_target = 500
      }
    }

    "sales-service-api" = {
      listener_port     = local.http_workloads["sales-service-api"].listener_port
      container_port    = local.http_workloads["sales-service-api"].port
      image             = local.images["sales-service"]
      cpu               = var.api_sizing["sales-service-api"].cpu
      memory            = var.api_sizing["sales-service-api"].memory
      desired_count     = local.desired["sales-service-api"]
      security_group_id = module.security.workload_security_group_ids["sales-service-api"]
      environment = {
        APP_ENV                     = "development"
        LOG_LEVEL                   = "INFO"
        SERVICE_NAME                = "sales-service"
        OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_endpoint
      }
      secrets = {
        DATABASE_URL = { secret_arn = module.db_sales.secret_arn, key = "database_url" }
      }
      autoscaling = {
        max_capacity    = var.api_sizing["sales-service-api"].max_capacity
        cpu_target      = 60
        requests_target = 500
      }
    }
  }

  # Same images as the APIs, different command (python -m app.cdc), no HTTP.
  workers = {
    "user-service-cdc" = {
      image             = local.images["user-service"]
      command           = ["python", "-m", "app.cdc"]
      cpu               = var.cdc_sizing["user-service-cdc"].cpu
      memory            = var.cdc_sizing["user-service-cdc"].memory
      desired_count     = local.desired["user-service-cdc"]
      security_group_id = module.security.workload_security_group_ids["user-service-cdc"]
      environment = {
        APP_ENV                     = "development"
        LOG_LEVEL                   = "INFO"
        KAFKA_BOOTSTRAP_SERVERS     = module.messaging.kafka_bootstrap_servers
        KAFKA_USERS_TOPIC           = "legacy.public.users"
        KAFKA_CONSUMER_GROUP        = "user-service-cdc"
        KAFKA_AUTO_OFFSET_RESET     = "earliest"
        CDC_METRICS_PORT            = tostring(local.worker_workloads["user-service-cdc"].metrics_port)
        OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_endpoint
      }
      secrets = {
        DATABASE_URL = { secret_arn = module.db_user.secret_arn, key = "database_url" }
      }
    }

    "sales-service-cdc" = {
      image             = local.images["sales-service"]
      command           = ["python", "-m", "app.cdc"]
      cpu               = var.cdc_sizing["sales-service-cdc"].cpu
      memory            = var.cdc_sizing["sales-service-cdc"].memory
      desired_count     = local.desired["sales-service-cdc"]
      security_group_id = module.security.workload_security_group_ids["sales-service-cdc"]
      environment = {
        APP_ENV                     = "development"
        LOG_LEVEL                   = "INFO"
        SERVICE_NAME                = "sales-service-cdc"
        KAFKA_BOOTSTRAP_SERVERS     = module.messaging.kafka_bootstrap_servers
        KAFKA_SALES_TOPIC           = "legacy.public.sales"
        KAFKA_CONSUMER_GROUP        = "sales-service-cdc"
        KAFKA_AUTO_OFFSET_RESET     = "earliest"
        CDC_METRICS_PORT            = tostring(local.worker_workloads["sales-service-cdc"].metrics_port)
        OTEL_EXPORTER_OTLP_ENDPOINT = local.otlp_endpoint
      }
      secrets = {
        DATABASE_URL = { secret_arn = module.db_sales.secret_arn, key = "database_url" }
      }
    }
  }
}

module "observability" {
  source = "../../modules/observability"

  name                      = local.name
  environment               = var.environment
  cluster_arn               = module.ecs_cluster.cluster_arn
  placement_attribute       = local.platform_attribute
  enable_otel_collector     = var.enable_otel_collector
  permissions_boundary_arn  = var.permissions_boundary_arn
  log_retention_days        = var.log_retention_days
  alarm_emails              = var.alarm_emails
  alb_arn_suffix            = module.compute.alb_arn_suffix
  target_group_arn_suffixes = module.compute.target_group_arn_suffixes
  cdc_source_database       = "legacy"

  databases = {
    legacy = module.db_legacy.instance_id
    user   = module.db_user.instance_id
    sales  = module.db_sales.instance_id
  }
}
