# DMS requires this service-linked role to manage VPC resources (ENIs, etc.)
resource "aws_iam_role" "dms_vpc_role" {
  name = "dms-vpc-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dms.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "dms_vpc_role" {
  role       = aws_iam_role.dms_vpc_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonDMSVPCManagementRole"
}

resource "aws_security_group" "dms_sg" {
  name        = "dms-sg"
  description = "Allow outbound traffic from DMS"

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  vpc_id = var.vpc_id
}

resource "aws_dms_replication_subnet_group" "dms" {
  replication_subnet_group_id          = "${var.resource_prefix}-subnet-group"
  replication_subnet_group_description = "Subnet group for DMS in customer sandbox VPC"
  subnet_ids                           = values(data.aws_subnet.private)[*].id

  depends_on = [aws_iam_role_policy_attachment.dms_vpc_role]
}

resource "aws_dms_replication_instance" "dms" {
  replication_instance_id    = var.resource_prefix
  replication_instance_class = "dms.t3.large"
  allocated_storage          = 50
  engine_version             = "3.6.1"

  publicly_accessible         = false
  multi_az                    = false
  replication_subnet_group_id = aws_dms_replication_subnet_group.dms.replication_subnet_group_id
  vpc_security_group_ids      = [aws_security_group.dms_sg.id]

  tags = {
    Name = var.resource_prefix
  }
}

# S3 bucket for DMS target (to be loaded into Snowflake)
resource "aws_s3_bucket" "dms_target" {
  bucket = "${var.resource_prefix}-target"
}

# SNS topic for Snowpipe: S3 publishes ObjectCreated events here,
# Snowflake subscribes via its SQS queue.
resource "aws_sns_topic" "dms_target" {
  name = "${var.resource_prefix}-target-snowpipe"
}

resource "aws_sns_topic_policy" "dms_target" {
  arn = aws_sns_topic.dms_target.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid       = "AllowS3Publish"
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "SNS:Publish"
        Resource  = aws_sns_topic.dms_target.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = aws_s3_bucket.dms_target.arn
          }
        }
      }],
      var.snowflake_iam_user_arn != null ? [{
        Sid       = "AllowSnowflakeSubscribe"
        Effect    = "Allow"
        Principal = { AWS = var.snowflake_iam_user_arn }
        Action    = ["SNS:Subscribe"]
        Resource  = aws_sns_topic.dms_target.arn
      }] : [],
    )
  })
}

resource "aws_s3_bucket_notification" "dms_target" {
  bucket = aws_s3_bucket.dms_target.id

  topic {
    topic_arn     = aws_sns_topic.dms_target.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "dms/"
  }

  depends_on = [aws_sns_topic_policy.dms_target]
}

resource "aws_iam_role" "dms_s3_role" {
  name = "${var.resource_prefix}-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dms.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "dms_s3_policy" {
  name = "${var.resource_prefix}-s3-policy"
  role = aws_iam_role.dms_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:DeleteObject", "s3:PutObjectTagging"]
      Resource = "${aws_s3_bucket.dms_target.arn}/*"
      }, {
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource = aws_s3_bucket.dms_target.arn
    }]
  })
}

resource "aws_iam_role" "snowflake_s3_role" {
  name = "${var.resource_prefix}-snowflake-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = var.snowflake_iam_user_arn != null ? [{
      Effect    = "Allow"
      Principal = { AWS = var.snowflake_iam_user_arn }
      Action    = "sts:AssumeRole"
      Condition = var.snowflake_storage_external_id != null ? {
        StringEquals = { "sts:ExternalId" = var.snowflake_storage_external_id }
      } : {}
      }] : [{
      Effect    = "Deny"
      Principal = { AWS = "*" }
      Action    = "sts:AssumeRole"
      Condition = {}
    }]
  })
}

resource "aws_iam_role_policy" "snowflake_s3_policy" {
  name = "${var.resource_prefix}-snowflake-s3-policy"
  role = aws_iam_role.snowflake_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject", "s3:GetObjectVersion"]
      Resource = "${aws_s3_bucket.dms_target.arn}/*"
      }, {
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
      Resource = aws_s3_bucket.dms_target.arn
    }]
  })
}

# Source endpoint: RDS Postgres from rds.tf
resource "aws_dms_endpoint" "source" {
  endpoint_id   = "${var.resource_prefix}-source"
  endpoint_type = "source"
  engine_name   = "postgres"

  server_name   = aws_db_instance.benchmark.address
  port          = aws_db_instance.benchmark.port
  username      = aws_db_instance.benchmark.username
  password      = var.db_password
  database_name = aws_db_instance.benchmark.db_name
  ssl_mode      = "require"
}

# Target endpoint: S3 (Parquet for Snowflake ingestion)
resource "aws_dms_s3_endpoint" "target" {
  endpoint_id   = "${var.resource_prefix}-target"
  endpoint_type = "target"

  bucket_name             = aws_s3_bucket.dms_target.id
  bucket_folder           = "dms"
  service_access_role_arn = aws_iam_role.dms_s3_role.arn
  data_format             = "parquet"
  compression_type        = "GZIP"
  timestamp_column_name   = "dms_timestamp"

}

output "dms_replication_instance_arn" {
  value = aws_dms_replication_instance.dms.replication_instance_arn
}

output "dms_source_endpoint_arn" {
  value = aws_dms_endpoint.source.endpoint_arn
}

output "dms_target_endpoint_arn" {
  value = aws_dms_s3_endpoint.target.endpoint_arn
}

output "dms_s3_bucket" {
  value = aws_s3_bucket.dms_target.bucket
}

output "dms_target_sns_topic_arn" {
  value = aws_sns_topic.dms_target.arn
}

output "snowflake_s3_role_arn" {
  value = aws_iam_role.snowflake_s3_role.arn
}
