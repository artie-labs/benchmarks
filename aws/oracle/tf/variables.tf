variable "region" {
  description = "The region to deploy the resources to."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "The profile to use for the AWS CLI."
  type        = string
  default     = null
}

variable "resource_prefix" {
  description = "The prefix for resource names. Every resource is also tagged Purpose=<prefix>."
  type        = string
  default     = "benchmark-oracle"
}

variable "availability_zone" {
  description = "The zone for both the database and the instance. Keeping them together keeps LogMiner traffic in one zone."
  type        = string
  default     = "us-west-2a"
}

variable "db_instance_class" {
  description = "The RDS class. Oracle SE2 with an included license is offered on m5, m8i, r5, r6i and r8i. Watch the database's CPU, and move to db.m8i.2xlarge if LogMiner pins it."
  type        = string
  default     = "db.m8i.xlarge"
}

variable "db_allocated_storage" {
  description = "Database storage in GB. Oracle on gp3 gets 12,000 IOPS and 500 MiB/s from 400 GB, and 3,000 IOPS and 125 MiB/s below it. Redo and archived logs share that bandwidth."
  type        = number
  default     = 400
}

variable "instance_type" {
  description = "The EC2 type that runs Kafka, Reader and Transfer."
  type        = string
  default     = "m7i.2xlarge"
}

variable "compose_version" {
  description = "The Docker Compose release installed on the instance."
  type        = string
  default     = "v5.7.0"
}
