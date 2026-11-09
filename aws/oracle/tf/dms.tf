# AWS DMS on the same database, for comparing with Reader and Debezium. Off by default. bench.py setup-dms creates
# the DMS_USER Oracle user from the secret below, and bench.py dms-drain runs one CDC task per drain.

variable "enable_dms" {
  description = "Create a DMS replication instance, Oracle source endpoints for LogMiner and Binary Reader, and an S3 target."
  type        = bool
  default     = false
}

variable "dms_instance_class" {
  description = "The DMS class. dms.c6i.2xlarge has 8 vCPUs, like the bench instance."
  type        = string
  default     = "dms.c6i.2xlarge"
}

locals {
  dms = var.enable_dms ? 1 : 0
}

# DMS needs this role, by this exact name, to place its instance in the VPC.
resource "aws_iam_role" "dms_vpc" {
  count = local.dms
  name  = "dms-vpc-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "dms.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "dms_vpc" {
  count      = local.dms
  role       = aws_iam_role.dms_vpc[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}

# Task logs go to CloudWatch through this role, also by its exact name.
resource "aws_iam_role" "dms_logs" {
  count = local.dms
  name  = "dms-cloudwatch-logs-role"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "dms.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy_attachment" "dms_logs" {
  count      = local.dms
  role       = aws_iam_role.dms_logs[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSCloudWatchLogsRole"
}

resource "random_password" "dms" {
  count   = local.dms
  length  = 24
  special = false
}

# DMS reads its Oracle credentials here, and bench.py setup-dms creates the user with them.
resource "aws_secretsmanager_secret" "dms" {
  count                   = local.dms
  name_prefix             = "${var.resource_prefix}-dms-"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "dms" {
  count     = local.dms
  secret_id = aws_secretsmanager_secret.dms[0].id
  secret_string = jsonencode({
    username = "DMS_USER"
    # Oracle passwords must start with a letter.
    password = "D${random_password.dms[0].result}"
    host     = aws_db_instance.oracle.address
    port     = 1521
    dbname   = "ORCL"
    engine   = "oracle"
  })
}

resource "aws_iam_role" "dms_access" {
  count = local.dms
  name  = "${var.resource_prefix}-dms-access"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "dms.${var.region}.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "dms_access" {
  count = local.dms
  name  = "${var.resource_prefix}-dms-access"
  role  = aws_iam_role.dms_access[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["secretsmanager:GetSecretValue"], Resource = aws_secretsmanager_secret.dms[0].arn },
      { Effect = "Allow", Action = ["s3:PutObject", "s3:DeleteObject", "s3:PutObjectTagging"], Resource = "${aws_s3_bucket.bench.arn}/dms/*" },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.bench.arn },
    ]
  })
}

# The S3 target assumes a role trusted by the global DMS principal.
resource "aws_iam_role" "dms_s3" {
  count = local.dms
  name  = "${var.resource_prefix}-dms-s3"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "dms.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
}

resource "aws_iam_role_policy" "dms_s3" {
  count = local.dms
  name  = "${var.resource_prefix}-dms-s3"
  role  = aws_iam_role.dms_s3[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:PutObject", "s3:DeleteObject", "s3:PutObjectTagging"], Resource = "${aws_s3_bucket.bench.arn}/dms/*" },
      { Effect = "Allow", Action = ["s3:ListBucket", "s3:GetBucketLocation"], Resource = aws_s3_bucket.bench.arn },
    ]
  })
}

resource "aws_security_group" "dms" {
  count       = local.dms
  name        = "${var.resource_prefix}-dms"
  description = "Oracle benchmark DMS instance, outbound only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_dms_replication_subnet_group" "dms" {
  count                                = local.dms
  replication_subnet_group_id          = var.resource_prefix
  replication_subnet_group_description = "Oracle benchmark DMS"
  subnet_ids                           = data.aws_subnets.default.ids
  depends_on                           = [aws_iam_role_policy_attachment.dms_vpc]
}

resource "aws_dms_replication_instance" "dms" {
  count                       = local.dms
  replication_instance_id     = var.resource_prefix
  replication_instance_class  = var.dms_instance_class
  engine_version              = "3.6.1"
  allocated_storage           = 100
  availability_zone           = var.availability_zone
  multi_az                    = false
  publicly_accessible         = false
  replication_subnet_group_id = aws_dms_replication_subnet_group.dms[0].replication_subnet_group_id
  vpc_security_group_ids      = [aws_security_group.dms[0].id]
  apply_immediately           = true
}

# The DMS instance has no public IP and the default VPC has no NAT gateway, so it reaches its credentials and its
# S3 target through VPC endpoints. With private DNS, the bench instance's Secrets Manager calls use the endpoint too.
resource "aws_vpc_endpoint" "s3" {
  count             = local.dms
  vpc_id            = data.aws_vpc.default.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [data.aws_vpc.default.main_route_table_id]
}

resource "aws_security_group" "endpoints" {
  count       = local.dms
  name        = "${var.resource_prefix}-endpoints"
  description = "HTTPS to the Secrets Manager endpoint from the default VPC"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [data.aws_vpc.default.cidr_block]
  }
}

resource "aws_vpc_endpoint" "secretsmanager" {
  count               = local.dms
  vpc_id              = data.aws_vpc.default.id
  service_name        = "com.amazonaws.${var.region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [data.aws_subnet.box.id]
  security_group_ids  = [aws_security_group.endpoints[0].id]
}

# LogMiner is DMS's default Oracle reader.
resource "aws_dms_endpoint" "logminer" {
  count                           = local.dms
  endpoint_id                     = "${var.resource_prefix}-logminer"
  endpoint_type                   = "source"
  engine_name                     = "oracle"
  database_name                   = "ORCL"
  secrets_manager_arn             = aws_secretsmanager_secret.dms[0].arn
  secrets_manager_access_role_arn = aws_iam_role.dms_access[0].arn
  depends_on                      = [aws_secretsmanager_secret_version.dms]
}

# Binary Reader reads redo files directly. On RDS it reads them through the ONLINELOG_DIR and ARCHIVELOG_DIR
# directories, which bench.py setup-dms creates, as BFILEs (useBfile=Y).
resource "aws_dms_endpoint" "binary_reader" {
  count                           = local.dms
  endpoint_id                     = "${var.resource_prefix}-binary-reader"
  endpoint_type                   = "source"
  engine_name                     = "oracle"
  database_name                   = "ORCL"
  secrets_manager_arn             = aws_secretsmanager_secret.dms[0].arn
  secrets_manager_access_role_arn = aws_iam_role.dms_access[0].arn
  extra_connection_attributes     = "useLogMinerReader=N;useBfile=Y;"
  depends_on                      = [aws_secretsmanager_secret_version.dms]
}

# Parquet, as Transfer writes to S3.
resource "aws_dms_s3_endpoint" "target" {
  count                   = local.dms
  endpoint_id             = "${var.resource_prefix}-s3"
  endpoint_type           = "target"
  bucket_name             = aws_s3_bucket.bench.id
  bucket_folder           = "dms"
  service_access_role_arn = aws_iam_role.dms_s3[0].arn
  data_format             = "parquet"
  parquet_version         = "parquet-2-0"
  timestamp_column_name   = "dms_commit_ts"
  # DMS writes a CDC file every 60 s by default. 10 s matches the flush interval transfer-drain gives Transfer.
  cdc_max_batch_interval = 10
  depends_on             = [aws_iam_role_policy.dms_s3]
}

output "dms" {
  value = var.enable_dms ? {
    replication_instance_arn = aws_dms_replication_instance.dms[0].replication_instance_arn
    logminer_endpoint_arn    = aws_dms_endpoint.logminer[0].endpoint_arn
    binary_endpoint_arn      = aws_dms_endpoint.binary_reader[0].endpoint_arn
    target_endpoint_arn      = aws_dms_s3_endpoint.target[0].endpoint_arn
    secret_arn               = aws_secretsmanager_secret.dms[0].arn
  } : null
}
