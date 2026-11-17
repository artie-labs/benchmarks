resource "aws_eip" "shared" {
  domain = "vpc"
  tags   = { Name = "${var.name}-shared" }
}

# The release regression battery (RESULTS.md, "Release regression battery") starts each stack on natpair v0.1.1
# with the v0.1.1 module, from a local checkout of the tag at <workspace>/natpair.worktrees/regress-v011, then moves
# the module and release to the candidate for the in-place self-update (here natpair.worktrees/regress-cand3, natpair
# bench/regress3). v0.1.1's module has no kernel input, so drop the kernel line while it's on v0.1.1.
# Earlier rounds pointed this at natpair.worktrees/<bench branch>, such as bench-ctfix (natpair bench/ctfix).
module "natpair" {
  source = "../../../../../natpair.worktrees/regress-cand3/terraform"

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

# Session Manager and Run Command for the bench, whatever the module's version grants: v0.1.1's NAT role allows only
# Session Manager's channels, and its NATs boot before the module attaches even that.
resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = var.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

  depends_on = [module.natpair]
}
