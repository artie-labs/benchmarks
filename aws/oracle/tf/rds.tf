data "aws_rds_engine_version" "oracle" {
  engine       = "oracle-se2"
  default_only = true
}

resource "aws_db_subnet_group" "db" {
  name       = var.resource_prefix
  subnet_ids = data.aws_subnets.default.ids
}

resource "aws_db_instance" "oracle" {
  identifier     = var.resource_prefix
  engine         = "oracle-se2"
  engine_version = data.aws_rds_engine_version.oracle.version_actual
  license_model  = "license-included"
  instance_class = var.db_instance_class
  # Artie can't replicate from a multi-tenant RDS database, so this is a non-CDB, like customers' databases.
  multi_tenant = false
  # The service name Reader connects to.
  db_name = "ORCL"

  allocated_storage = var.db_allocated_storage
  storage_type      = "gp3"
  storage_encrypted = true

  username = "admin"
  # RDS keeps the password in Secrets Manager, and bench.py reads it there.
  manage_master_user_password = true

  availability_zone      = var.availability_zone
  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false

  # RDS for Oracle only archives redo logs when automated backups are on, and LogMiner reads the archived logs.
  # One day is the shortest retention. bench.py setup sets how long the logs stay on the instance.
  backup_retention_period = 1
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  # Shows where database time goes, such as LogMiner's sessions. Seven days of retention are free.
  performance_insights_enabled = true
}
