# -----------------------------------------------------------------------------
# Kafka (KRaft, single node) and Kafka Connect + Debezium on the platform host.
#
# Terraform provisions the RUNTIME (containers, network, storage, credentials).
# It does NOT register the Debezium connector, create the publication or the
# replication slot: those are runtime/database operations, see
# docs/runbooks/cdc-bootstrap.md and docs/adr/0002-kafka-platform.md.
# -----------------------------------------------------------------------------

locals {
  kafka_host   = "kafka.${var.namespace_name}"
  kafka_port   = 9092
  connect_host = "connect.${var.namespace_name}"
}

# --- Debezium credentials (the DB role itself is created by the CDC runbook) ------
ephemeral "random_password" "debezium" {
  length           = 32
  special          = true
  override_special = "-_"
}

resource "aws_secretsmanager_secret" "debezium" {
  name                    = "${var.name_prefix}/${var.environment}/legacy-debezium"
  description             = "Replication user used by Debezium on the legacy database"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "debezium" {
  secret_id = aws_secretsmanager_secret.debezium.id
  secret_string_wo = jsonencode({
    username = "debezium"
    password = ephemeral.random_password.debezium.result
  })
  secret_string_wo_version = var.debezium_password_version
}

# --- Kafka ----------------------------------------------------------------------------
module "kafka" {
  source = "../ecs-service"

  name                     = "${var.name}-kafka"
  container_name           = "kafka"
  cluster_arn              = var.cluster_arn
  launch                   = "ec2_host"
  image                    = var.kafka_image
  memory                   = 1536
  memory_reservation       = 1024
  desired_count            = 1
  port_mappings            = [local.kafka_port]
  placement_attribute      = var.placement_attribute
  mount_points             = { "/var/lib/kafka/data" = "/data/kafka" }
  ulimits_nofile           = 65536
  stop_timeout             = 60
  enable_execute_command   = true
  permissions_boundary_arn = var.permissions_boundary_arn
  log_retention_days       = var.log_retention_days

  environment = {
    KAFKA_NODE_ID                                  = "1"
    KAFKA_PROCESS_ROLES                            = "broker,controller"
    KAFKA_CONTROLLER_QUORUM_VOTERS                 = "1@localhost:9093"
    CLUSTER_ID                                     = var.kafka_cluster_id
    KAFKA_LISTENERS                                = "BROKER://0.0.0.0:${local.kafka_port},CONTROLLER://localhost:9093"
    KAFKA_ADVERTISED_LISTENERS                     = "BROKER://${local.kafka_host}:${local.kafka_port}"
    KAFKA_LISTENER_SECURITY_PROTOCOL_MAP           = "CONTROLLER:PLAINTEXT,BROKER:PLAINTEXT"
    KAFKA_CONTROLLER_LISTENER_NAMES                = "CONTROLLER"
    KAFKA_INTER_BROKER_LISTENER_NAME               = "BROKER"
    KAFKA_OFFSETS_TOPIC_REPLICATION_FACTOR         = "1"
    KAFKA_TRANSACTION_STATE_LOG_REPLICATION_FACTOR = "1"
    KAFKA_TRANSACTION_STATE_LOG_MIN_ISR            = "1"
    KAFKA_GROUP_INITIAL_REBALANCE_DELAY_MS         = "0"
    KAFKA_AUTO_CREATE_TOPICS_ENABLE                = "true"
    KAFKA_NUM_PARTITIONS                           = tostring(var.kafka_default_partitions)
    KAFKA_LOG_DIRS                                 = "/var/lib/kafka/data"
    KAFKA_LOG_RETENTION_HOURS                      = "168"
    KAFKA_HEAP_OPTS                                = "-Xms512m -Xmx768m"
  }

  health_check_command      = "/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:${local.kafka_port} >/dev/null 2>&1 || exit 1"
  health_check_start_period = 60

  depends_on = [aws_volume_attachment.data]
}

# --- Kafka Connect + Debezium ------------------------------------------------------
module "connect" {
  source = "../ecs-service"

  name                     = "${var.name}-kafka-connect"
  container_name           = "connect"
  cluster_arn              = var.cluster_arn
  launch                   = "ec2_host"
  image                    = var.connect_image
  memory                   = 1536
  memory_reservation       = 1024
  desired_count            = 1
  port_mappings            = [8083]
  placement_attribute      = var.placement_attribute
  stop_timeout             = 60
  enable_execute_command   = true
  permissions_boundary_arn = var.permissions_boundary_arn
  log_retention_days       = var.log_retention_days

  environment = {
    BOOTSTRAP_SERVERS                      = "${local.kafka_host}:${local.kafka_port}"
    GROUP_ID                               = "cdc-connect-cluster"
    CONFIG_STORAGE_TOPIC                   = "_connect_configs"
    OFFSET_STORAGE_TOPIC                   = "_connect_offsets"
    STATUS_STORAGE_TOPIC                   = "_connect_status"
    CONFIG_STORAGE_REPLICATION_FACTOR      = "1"
    OFFSET_STORAGE_REPLICATION_FACTOR      = "1"
    STATUS_STORAGE_REPLICATION_FACTOR      = "1"
    OFFSET_FLUSH_INTERVAL_MS               = "10000"
    KEY_CONVERTER                          = "org.apache.kafka.connect.json.JsonConverter"
    VALUE_CONVERTER                        = "org.apache.kafka.connect.json.JsonConverter"
    CONNECT_KEY_CONVERTER_SCHEMAS_ENABLE   = "false"
    CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE = "false"
    ADVERTISED_HOST_NAME                   = local.connect_host
    KAFKA_HEAP_OPTS                        = "-Xms512m -Xmx1g"

    # Lets connector configs reference ${env:DEBEZIUM_DB_PASSWORD} so the
    # password never travels in the REST payload or sits in _connect_configs.
    CONNECT_CONFIG_PROVIDERS           = "env"
    CONNECT_CONFIG_PROVIDERS_ENV_CLASS = "org.apache.kafka.common.config.provider.EnvVarConfigProvider"

    LEGACY_DB_HOST = var.legacy_db_address
    LEGACY_DB_NAME = var.legacy_db_name
  }

  secrets = {
    DEBEZIUM_DB_USER     = { secret_arn = aws_secretsmanager_secret.debezium.arn, key = "username" }
    DEBEZIUM_DB_PASSWORD = { secret_arn = aws_secretsmanager_secret.debezium.arn, key = "password" }
  }

  health_check_command      = "curl -sf http://localhost:8083/ >/dev/null || exit 1"
  health_check_start_period = 90

  depends_on = [aws_secretsmanager_secret_version.debezium]
}
