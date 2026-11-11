data "aws_caller_identity" "current" {}

data "aws_ami" "al2023_arm64" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-*-arm64"]
  }
}

resource "aws_iam_role" "box" {
  name = "${var.name}-box"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "box_ssm" {
  role       = aws_iam_role.box.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The receiver runs the job queue. It starts tools on the NATs and generators through SSM Run Command, finds the
# owner from the shared ENI's attachment, and puts a NAT in maintenance for the handover test.
resource "aws_iam_role_policy" "box" {
  name = "${var.name}-box"
  role = aws_iam_role.box.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:ListBucket"]
        Resource = [aws_s3_bucket.bench.arn, "${aws_s3_bucket.bench.arn}/*"]
      },
      {
        Effect    = "Allow"
        Action    = "ssm:SendCommand"
        Resource  = "arn:aws:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = { StringEquals = { "ssm:resourceTag/bench" = "natpair" } }
      },
      {
        Effect   = "Allow"
        Action   = "ssm:SendCommand"
        Resource = "arn:aws:ssm:${var.region}::document/AWS-RunShellScript"
      },
      {
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ec2:DescribeNetworkInterfaces", "ec2:DescribeInstances"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_instance_profile" "box" {
  name = "${var.name}-box"
  role = aws_iam_role.box.name
}

locals {
  box_user_data = {
    bucket            = aws_s3_bucket.bench.id
    region            = var.region
    auto_stop_minutes = var.auto_stop_minutes
  }
}

resource "aws_instance" "generator" {
  count = var.generator_count

  ami                                  = data.aws_ami.al2023_arm64.id
  instance_type                        = var.generator_instance_type
  subnet_id                            = aws_subnet.worker.id
  vpc_security_group_ids               = [aws_security_group.generator.id]
  iam_instance_profile                 = aws_iam_instance_profile.box.name
  instance_initiated_shutdown_behavior = "stop"
  user_data                            = templatefile("${path.module}/user_data.sh.tftpl", merge(local.box_user_data, { role = "generator" }))
  user_data_replace_on_change          = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  # The generators install packages through the S3 endpoint and register with SSM through the NAT, so the pair must
  # be up first.
  depends_on = [aws_s3_object.box, aws_iam_role_policy.box, aws_route.worker_default, aws_vpc_endpoint.s3_test]

  tags = { Name = "${var.name}-gen-${count.index}" }
}

resource "aws_instance" "receiver" {
  ami                                  = data.aws_ami.al2023_arm64.id
  instance_type                        = var.receiver_instance_type
  subnet_id                            = aws_subnet.receiver.id
  vpc_security_group_ids               = [aws_security_group.receiver.id]
  iam_instance_profile                 = aws_iam_instance_profile.box.name
  instance_initiated_shutdown_behavior = "stop"
  user_data                            = templatefile("${path.module}/user_data.sh.tftpl", merge(local.box_user_data, { role = "receiver" }))
  user_data_replace_on_change          = true

  root_block_device {
    volume_type = "gp3"
    volume_size = 8
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
  }

  depends_on = [aws_s3_object.box, aws_iam_role_policy.box, aws_route.receiver_to_test, aws_vpc_endpoint.s3_receiver]

  tags = { Name = "${var.name}-receiver" }
}

# The job queue reads the bench layout from here before each job, so new NATs or generators need no change on the
# receiver.
resource "aws_s3_object" "bench_env" {
  bucket = aws_s3_bucket.bench.id
  key    = "bench.env"
  content = join("\n", [
    "GENERATORS='${join(" ", aws_instance.generator[*].id)}'",
    "GENERATOR_IPS='${join(" ", aws_instance.generator[*].private_ip)}'",
    "NAT_A=${module.natpair.nat_instance_ids["a"]}",
    "NAT_B=${module.natpair.nat_instance_ids["b"]}",
    "SHARED_ENI=${module.natpair.shared_eni_id}",
    "NAT_INSTANCE_TYPE=${var.nat_instance_type}",
    "GENERATOR_INSTANCE_TYPE=${var.generator_instance_type}",
    "RECEIVER_INSTANCE_TYPE=${var.receiver_instance_type}",
    "NATPAIR_RELEASE=${var.natpair_release}",
    "",
  ])
}
