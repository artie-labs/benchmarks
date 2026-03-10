data "aws_subnet" "public" {
  for_each = var.public_subnet_ids
  id       = each.value
}

data "aws_subnet" "private" {
  for_each = var.private_subnet_ids
  id       = each.value
}
