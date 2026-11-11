# Two VPCs in one zone, peered. The test VPC holds the NATs (public subnet) and the load generators (worker subnet,
# default route through the shared ENI). The receiver VPC holds the iperf3 servers. Workers reach the receiver through
# the NAT, because only the NATs' public route table routes the receiver's CIDR over the peering. natpair translates
# every worker packet to the shared ENI's private address, whatever the destination, so this path loads the NAT
# exactly like internet traffic without paying for public data transfer.

locals {
  test_cidr     = "10.40.0.0/16"
  public_cidr   = "10.40.0.0/24"
  worker_cidr   = "10.40.1.0/24"
  receiver_cidr = "10.50.0.0/16"
}

resource "aws_vpc" "test" {
  cidr_block           = local.test_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-test" }
}

resource "aws_internet_gateway" "test" {
  vpc_id = aws_vpc.test.id
  tags   = { Name = "${var.name}-test" }
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.test.id
  cidr_block        = local.public_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${var.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.test.id
  tags   = { Name = "${var.name}-public" }
}

resource "aws_route" "public_default" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.test.id
}

# Translated worker traffic leaves the shared ENI with the shared ENI's private address and takes this route.
resource "aws_route" "public_to_receiver" {
  route_table_id            = aws_route_table.public.id
  destination_cidr_block    = local.receiver_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.bench.id
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "worker" {
  vpc_id            = aws_vpc.test.id
  cidr_block        = local.worker_cidr
  availability_zone = var.availability_zone
  tags              = { Name = "${var.name}-worker" }
}

# Only the default route, through the shared ENI. Adding the receiver's CIDR here would bypass the NAT.
resource "aws_route_table" "worker" {
  vpc_id = aws_vpc.test.id
  tags   = { Name = "${var.name}-worker" }
}

resource "aws_route" "worker_default" {
  route_table_id         = aws_route_table.worker.id
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = module.natpair.shared_eni_id
}

resource "aws_route_table_association" "worker" {
  subnet_id      = aws_subnet.worker.id
  route_table_id = aws_route_table.worker.id
}

resource "aws_vpc" "receiver" {
  cidr_block           = local.receiver_cidr
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-receiver" }
}

# The receiver's own path to SSM and package mirrors. Bench traffic never uses it.
resource "aws_internet_gateway" "receiver" {
  vpc_id = aws_vpc.receiver.id
  tags   = { Name = "${var.name}-receiver" }
}

resource "aws_subnet" "receiver" {
  vpc_id                  = aws_vpc.receiver.id
  cidr_block              = "10.50.0.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-receiver" }
}

resource "aws_route_table" "receiver" {
  vpc_id = aws_vpc.receiver.id
  tags   = { Name = "${var.name}-receiver" }
}

resource "aws_route" "receiver_default" {
  route_table_id         = aws_route_table.receiver.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.receiver.id
}

resource "aws_route" "receiver_to_test" {
  route_table_id            = aws_route_table.receiver.id
  destination_cidr_block    = local.test_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.bench.id
}

resource "aws_route_table_association" "receiver" {
  subnet_id      = aws_subnet.receiver.id
  route_table_id = aws_route_table.receiver.id
}

resource "aws_vpc_peering_connection" "bench" {
  vpc_id      = aws_vpc.test.id
  peer_vpc_id = aws_vpc.receiver.id
  auto_accept = true
  tags        = { Name = var.name }
}

# Free S3 paths for package mirrors (Amazon Linux's are in S3), box files and results, so none of it crosses the NAT.
resource "aws_vpc_endpoint" "s3_test" {
  vpc_id            = aws_vpc.test.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id, aws_route_table.worker.id]
  tags              = { Name = "${var.name}-test-s3" }
}

resource "aws_vpc_endpoint" "s3_receiver" {
  vpc_id            = aws_vpc.receiver.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.receiver.id]
  tags              = { Name = "${var.name}-receiver-s3" }
}

resource "aws_security_group" "generator" {
  name        = "${var.name}-generator"
  description = "natpair bench load generators"
  vpc_id      = aws_vpc.test.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.test_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "receiver" {
  name        = "${var.name}-receiver"
  description = "natpair bench receiver, reachable from the test VPC only"
  vpc_id      = aws_vpc.receiver.id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.test_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
