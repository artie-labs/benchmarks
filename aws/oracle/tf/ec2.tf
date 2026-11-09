data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "box" {
  name               = "${var.resource_prefix}-box"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "box_ssm" {
  role       = aws_iam_role.box.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "box" {
  # images/ holds Reader and Transfer builds that aren't on Docker Hub, as docker save archives.
  statement {
    sid       = "ReadBox"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.bench.arn}/box/*", "${aws_s3_bucket.bench.arn}/images/*"]
  }

  statement {
    sid       = "UploadResults"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.bench.arn}/results/*"]
  }

  statement {
    sid       = "ListBox"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.bench.arn]
  }

  statement {
    sid       = "ReadMasterPassword"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = concat([aws_db_instance.oracle.master_user_secret[0].secret_arn], aws_secretsmanager_secret.dms[*].arn)
  }

  # bench.py records the database's class with each result, and reads its CPU and I/O for a drain's window.
  statement {
    sid       = "DescribeDatabase"
    actions   = ["rds:DescribeDBInstances"]
    resources = [aws_db_instance.oracle.arn]
  }

  statement {
    sid       = "ReadDatabaseMetrics"
    actions   = ["cloudwatch:GetMetricStatistics"]
    resources = ["*"]
  }

  statement {
    sid       = "AssumeTransferRole"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.transfer.arn]
  }
}

resource "aws_iam_role_policy" "box" {
  name   = "${var.resource_prefix}-box"
  role   = aws_iam_role.box.id
  policy = data.aws_iam_policy_document.box.json
}

resource "aws_iam_instance_profile" "box" {
  name = "${var.resource_prefix}-box"
  role = aws_iam_role.box.name
}

# Transfer's S3 destination takes static keys or a role to assume. It reaches this role with the instance's own
# credentials, so no access keys exist.
data "aws_iam_policy_document" "transfer_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.box.arn]
    }
  }
}

resource "aws_iam_role" "transfer" {
  name               = "${var.resource_prefix}-transfer"
  assume_role_policy = data.aws_iam_policy_document.transfer_assume.json
}

data "aws_iam_policy_document" "transfer" {
  statement {
    actions   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.bench.arn}/transfer/*"]
  }

  statement {
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.bench.arn]
  }
}

resource "aws_iam_role_policy" "transfer" {
  name   = "${var.resource_prefix}-transfer"
  role   = aws_iam_role.transfer.id
  policy = data.aws_iam_policy_document.transfer.json
}

resource "aws_instance" "box" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.box.id
  vpc_security_group_ids = [aws_security_group.box.id]
  iam_instance_profile   = aws_iam_instance_profile.box.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 100
    encrypted   = true
  }

  metadata_options {
    http_tokens = "required"
    # Transfer reads the instance's credentials from inside a container, one network hop past the default limit.
    http_put_response_hop_limit = 2
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    bucket            = aws_s3_bucket.bench.id
    region            = var.region
    compose_version   = var.compose_version
    oracle_host       = aws_db_instance.oracle.address
    master_secret_arn = aws_db_instance.oracle.master_user_secret[0].secret_arn
    db_instance_id    = aws_db_instance.oracle.identifier
    transfer_role_arn = aws_iam_role.transfer.arn
  })
  user_data_replace_on_change = true

  # The instance syncs the box folder on its first boot, so upload it first.
  depends_on = [aws_s3_object.box, aws_iam_role_policy.box]

  tags = {
    Name = var.resource_prefix
  }
}

variable "replay_box" {
  description = "Create a second instance, without its own database, for benchmarks that don't need Oracle (the demos LogMiner replay, local Oracle Free containers). It runs jobs from images/queue-replay/."
  type        = bool
  default     = false
}

resource "aws_instance" "replay" {
  count                  = var.replay_box ? 1 : 0
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.box.id
  vpc_security_group_ids = [aws_security_group.box.id]
  iam_instance_profile   = aws_iam_instance_profile.box.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 100
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # The same setup as the main instance, so jobs written for one run on the other.
  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    bucket            = aws_s3_bucket.bench.id
    region            = var.region
    compose_version   = var.compose_version
    oracle_host       = aws_db_instance.oracle.address
    master_secret_arn = aws_db_instance.oracle.master_user_secret[0].secret_arn
    db_instance_id    = aws_db_instance.oracle.identifier
    transfer_role_arn = aws_iam_role.transfer.arn
  })
  user_data_replace_on_change = true

  depends_on = [aws_s3_object.box, aws_iam_role_policy.box]

  tags = {
    Name = "${var.resource_prefix}-replay"
  }
}

output "replay_instance_id" {
  value = var.replay_box ? aws_instance.replay[0].id : null
}
