# Public path to RDS for Openflow on a Snowflake deployment (SPCS). SPCS runs outside this VPC, and RDS sits in the
# private subnets (default route via NAT), so flipping publicly_accessible on RDS wouldn't make it reachable, and
# moving it to the public subnets would recreate it. Instead, an internet-facing NLB in the public subnets forwards
# 5432 to RDS's private IP, and only Snowflake's egress CIDRs may connect. The NLB needs a public subnet in RDS's
# availability zone, or the target stays unused. RDS and the tools that connect inside the VPC are unchanged.
# Off by default; set openflow_public_access = true and snowflake_egress_cidrs to create it.

locals {
  openflow = var.openflow_public_access ? 1 : 0
}

# RDS's network interface, for its private IP. The NLB targets the IP, since an NLB can't target an RDS instance.
# A single-AZ instance keeps its IP across reboots, but not across a replace or a restore: rerun apply after either.
data "aws_network_interface" "rds" {
  count = local.openflow

  filter {
    name   = "group-id"
    values = [aws_security_group.rds_sg.id]
  }
  filter {
    name   = "description"
    values = ["RDSNetworkInterface"]
  }

  depends_on = [aws_db_instance.benchmark]
}

resource "aws_security_group" "openflow_nlb" {
  count       = local.openflow
  name        = "${var.resource_prefix}-openflow-nlb"
  description = "Postgres from Snowflake (Openflow) egress IPs to the RDS forwarder"
  vpc_id      = var.vpc_id

  ingress {
    description = "Snowflake egress"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = var.snowflake_egress_cidrs
  }

  egress {
    description = "To RDS"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["${data.aws_network_interface.rds[0].private_ip}/32"]
  }

  lifecycle {
    precondition {
      condition     = length(var.snowflake_egress_cidrs) > 0
      error_message = "Set snowflake_egress_cidrs (SELECT SYSTEM$GET_SNOWFLAKE_EGRESS_IP_RANGES()) before enabling openflow_public_access."
    }
  }
}

resource "aws_lb" "openflow" {
  count              = local.openflow
  name               = "${var.resource_prefix}-openflow"
  internal           = false
  load_balancer_type = "network"
  subnets            = values(data.aws_subnet.public)[*].id
  security_groups    = [aws_security_group.openflow_nlb[0].id]
}

# Client IP preservation is off, so RDS sees the NLB's private IPs in the public subnets, which rds_sg already allows.
resource "aws_lb_target_group" "openflow" {
  count                  = local.openflow
  name                   = "${var.resource_prefix}-openflow-pg"
  port                   = 5432
  protocol               = "TCP"
  target_type            = "ip"
  vpc_id                 = var.vpc_id
  preserve_client_ip     = "false"
  connection_termination = true

  health_check {
    protocol = "TCP"
    port     = "5432"
  }
}

resource "aws_lb_target_group_attachment" "openflow" {
  count            = local.openflow
  target_group_arn = aws_lb_target_group.openflow[0].arn
  target_id        = data.aws_network_interface.rds[0].private_ip
  port             = 5432
}

resource "aws_lb_listener" "openflow" {
  count             = local.openflow
  load_balancer_arn = aws_lb.openflow[0].arn
  port              = 5432
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.openflow[0].arn
  }
}

# Host for Openflow's JDBC URL and the Snowflake network rule (<host>:5432). The RDS certificate is for the RDS
# hostname, so connect with sslmode=require, not verify-full.
output "openflow_pg_host" {
  value = var.openflow_public_access ? aws_lb.openflow[0].dns_name : null
}
