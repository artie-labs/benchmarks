locals {
  box_dir   = "${path.module}/../box"
  box_files = [for f in fileset(local.box_dir, "**") : f if !startswith(f, ".")]
}

# Holds the box folder, which every bench instance syncs, job scripts (jobs/), raw run files (runs/) and summaries
# (results/).
resource "aws_s3_bucket" "bench" {
  bucket_prefix = "${var.name}-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "bench" {
  bucket                  = aws_s3_bucket.bench.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "box" {
  for_each = toset(local.box_files)

  bucket = aws_s3_bucket.bench.id
  key    = "box/${each.value}"
  source = "${local.box_dir}/${each.value}"
  etag   = filemd5("${local.box_dir}/${each.value}")
}
