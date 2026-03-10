resource "aws_security_group" "rds_sg" {
  name        = "rds-sg"
  description = "Allow inbound traffic to RDS"

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = concat(values(data.aws_subnet.public)[*].cidr_block, values(data.aws_subnet.private)[*].cidr_block)
  }
  vpc_id = var.vpc_id
}

# DB subnet group so RDS is placed in aws_vpc.main's private subnets (not default VPC)
resource "aws_db_subnet_group" "benchmark" {
  name        = "benchmark-db-subnet-group"
  description = "Subnet group for benchmark RDS in customer sandbox VPC"
  subnet_ids  = values(data.aws_subnet.private)[*].id
}

resource "aws_db_parameter_group" "benchmark" {
  name   = "benchmark-postgres18"
  family = "postgres18"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot"
  }

  parameter {
    name  = "synchronous_commit"
    value = "off"
  }
}

# Create the RDS instance
resource "aws_db_instance" "benchmark" {
  allocated_storage    = 100
  storage_type         = "gp3"
  engine               = "postgres"
  engine_version       = "18.1"
  instance_class       = "db.m7i.2xlarge"
  db_name              = "postgres"
  username             = "dbuser"
  password             = var.db_password
  parameter_group_name = aws_db_parameter_group.benchmark.name
  storage_encrypted    = true

  skip_final_snapshot    = true
  publicly_accessible    = false
  db_subnet_group_name   = aws_db_subnet_group.benchmark.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  backup_retention_period = 0
  multi_az                = false

  lifecycle {
    precondition {
      condition     = var.db_password != null && trimspace(var.db_password) != ""
      error_message = "db_password must be set and non-empty."
    }
  }
}

# Output the RDS endpoint
output "rds_endpoint" {
  value = length(aws_db_instance.benchmark) >= 1 ? aws_db_instance.benchmark.endpoint : null
}
