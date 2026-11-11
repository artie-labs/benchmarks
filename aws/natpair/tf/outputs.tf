data "aws_network_interface" "shared" {
  id = module.natpair.shared_eni_id
}

output "bucket" {
  value = aws_s3_bucket.bench.id
}

output "receiver_id" {
  value = aws_instance.receiver.id
}

output "generator_ids" {
  value = aws_instance.generator[*].id
}

output "nat_instance_ids" {
  value = module.natpair.nat_instance_ids
}

output "shared_eni_id" {
  value = module.natpair.shared_eni_id
}

output "shared_private_ip" {
  description = "The address the receiver should see as the source of all worker traffic."
  value       = data.aws_network_interface.shared.private_ip
}

output "connect_receiver" {
  description = "Opens a shell on the receiver, which runs the job queue. Needs the Session Manager plugin."
  value       = "aws ssm start-session${var.aws_profile == null ? "" : " --profile ${var.aws_profile}"} --region ${var.region} --target ${aws_instance.receiver.id}"
}
