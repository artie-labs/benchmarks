output "instance_id" {
  value = aws_instance.box.id
}

output "connect" {
  description = "Opens a shell on the instance. Needs the Session Manager plugin for the AWS CLI."
  value       = "aws ssm start-session${var.aws_profile == null ? "" : " --profile ${var.aws_profile}"} --region ${var.region} --target ${aws_instance.box.id}"
}

output "oracle_host" {
  value = aws_db_instance.oracle.address
}

output "db_instance_id" {
  value = aws_db_instance.oracle.identifier
}

output "bucket" {
  value = aws_s3_bucket.bench.id
}
