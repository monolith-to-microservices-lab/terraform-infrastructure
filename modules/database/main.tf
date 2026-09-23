# -----------------------------------------------------------------------------
# One RDS PostgreSQL instance + its connection secret.
#
# Password handling: an ephemeral random password is sent to RDS and to
# Secrets Manager through WRITE-ONLY arguments, so it is never written to the
# plan or to terraform.tfstate. Rotate by bumping var.password_version.
# -----------------------------------------------------------------------------

ephemeral "random_password" "master" {
  length           = 32
  special          = true
  override_special = "-_" # URL-safe: the password is embedded in DATABASE_URL
}

resource "aws_security_group" "this" {
  name        = var.name
  description = "PostgreSQL ${var.name}: only listed workloads"
  vpc_id      = var.vpc_id

  tags = { Name = var.name }
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  for_each = var.allowed_security_group_ids

  security_group_id            = aws_security_group.this.id
  description                  = "PostgreSQL from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = each.value
}

resource "aws_db_subnet_group" "this" {
  name       = var.name
  subnet_ids = var.subnet_ids
}

resource "aws_db_parameter_group" "this" {
  name_prefix = "${var.name}-"
  family      = "postgres${split(".", var.engine_version)[0]}"
  description = "Parameters for ${var.name}"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  dynamic "parameter" {
    for_each = var.logical_replication ? [1] : []
    content {
      # Equivalent of wal_level=logical on RDS. Static: needs a reboot when
      # changed on an existing instance (applied at boot for a new one).
      name         = "rds.logical_replication"
      value        = "1"
      apply_method = "pending-reboot"
    }
  }

  dynamic "parameter" {
    for_each = var.logical_replication ? [1] : []
    content {
      name  = "max_slot_wal_keep_size"
      value = tostring(var.max_slot_wal_keep_size_mb)
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = var.engine_version
  instance_class = var.instance_class

  db_name  = var.db_name
  username = var.username

  password_wo         = ephemeral.random_password.master.result
  password_wo_version = var.password_version

  allocated_storage     = var.allocated_storage
  max_allocated_storage = var.max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = var.multi_az

  backup_retention_period   = var.backup_retention_days
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-final"

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false
  apply_immediately           = var.apply_immediately

  # Free; password auth keeps working. Lets operators use short-lived IAM tokens.
  iam_database_authentication_enabled = true

  enabled_cloudwatch_logs_exports = []
  performance_insights_enabled    = false
  monitoring_interval             = 0

  tags = { Name = var.name }

  lifecycle {
    prevent_destroy = true
  }
}

# --- Connection secret ------------------------------------------------------------
resource "aws_secretsmanager_secret" "this" {
  name                    = var.secret_name
  description             = "Connection data for ${var.name}"
  recovery_window_in_days = var.secret_recovery_window_days
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id

  secret_string_wo = jsonencode({
    engine       = "postgres"
    host         = aws_db_instance.this.address
    port         = aws_db_instance.this.port
    dbname       = var.db_name
    username     = var.username
    password     = ephemeral.random_password.master.result
    database_url = "${var.sqlalchemy_driver}://${var.username}:${ephemeral.random_password.master.result}@${aws_db_instance.this.address}:${aws_db_instance.this.port}/${var.db_name}"
  })
  secret_string_wo_version = var.password_version
}
