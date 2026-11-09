# The default VPC's subnets are public, so the instance pulls images without a NAT gateway. Nothing accepts inbound
# traffic from the internet: the instance has no ingress rule and is reached through SSM, and the database only
# accepts the instance.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "box" {
  vpc_id            = data.aws_vpc.default.id
  availability_zone = var.availability_zone
  default_for_az    = true
}

resource "aws_security_group" "box" {
  name        = "${var.resource_prefix}-box"
  description = "Oracle benchmark instance, outbound only"
  vpc_id      = data.aws_vpc.default.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name        = "${var.resource_prefix}-db"
  description = "Oracle benchmark database, reachable from the benchmark instance only"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 1521
    to_port         = 1521
    protocol        = "tcp"
    security_groups = [aws_security_group.box.id]
  }

  # DMS, when enable_dms is on. Inline rules replace any added separately, so DMS's rule is here too.
  dynamic "ingress" {
    for_each = aws_security_group.dms[*].id
    content {
      from_port       = 1521
      to_port         = 1521
      protocol        = "tcp"
      security_groups = [ingress.value]
    }
  }
}
