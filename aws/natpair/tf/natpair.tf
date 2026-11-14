resource "aws_eip" "shared" {
  domain = "vpc"
  tags   = { Name = "${var.name}-shared" }
}

# Phases 2 and 3 and the release candidate run dev builds of natpair v0.1.99 (see RESULTS.md), so the module comes
# from a local checkout of the same commit, which matches the build's install.sh. The path assumes this repo is at
# <workspace>/benchmarks.worktrees/<name> and natpair's bench/release branch at <workspace>/natpair.worktrees/release.
# Phase 1 used git::https://github.com/artie-labs/natpair.git//terraform?ref=v0.1.1 with the v0.1.1 release.
module "natpair" {
  source = "../../../../../natpair.worktrees/release-udp/terraform"

  name    = var.name
  pair_id = var.name

  public_subnet_id         = aws_subnet.public.id
  public_route_table_id    = aws_route_table.public.id
  shared_eip_allocation_id = aws_eip.shared.allocation_id

  instance_type = var.nat_instance_type
  kernel        = var.nat_kernel

  release        = var.natpair_release
  release_sha256 = var.natpair_release_sha256
  release_url    = var.natpair_release_url
}

# The bench tools on the NATs (enapoll, mpstat) come from the bench bucket, and their output goes back to it. The
# module names the NATs' role after var.name. This adds to it without changing the module.
resource "aws_iam_role_policy" "nat_bench" {
  name = "${var.name}-bench"
  role = var.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "s3:GetObject", Resource = "${aws_s3_bucket.bench.arn}/box/*" },
      { Effect = "Allow", Action = "s3:PutObject", Resource = "${aws_s3_bucket.bench.arn}/runs/*" },
    ]
  })

  depends_on = [module.natpair]
}
