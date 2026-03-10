variable "region" {
  description = "The region to deploy the resources to."
  type        = string
  default     = null
}

variable "aws_profile" {
  description = "The profile to use for the AWS CLI."
  type        = string
  default     = null
}

variable "vpc_id" {
  description = "The ID of the VPC."
  type        = string
  default     = null
}

variable "public_subnet_ids" {
  description = "The IDs of the public subnets."
  type        = set(string)
  default     = null
}

variable "private_subnet_ids" {
  description = "The IDs of the private subnets."
  type        = set(string)
  default     = null
}

variable "db_password" {
  description = "The password for the RDS instance."
  type        = string
  default     = null
  sensitive   = true
}

variable "snowflake_iam_user_arn" {
  description = "Snowflake IAM user ARN (Run SELECT SYSTEM$GET_AWS_SNS_IAM_POLICY('<topic_arn>') in Snowflake to get this value.). Used for both the storage integration role trust and the Snowpipe SNS subscribe policy."
  type        = string
  default     = null
}

variable "snowflake_storage_external_id" {
  description = "Snowflake external ID (STORAGE_AWS_EXTERNAL_ID from DESC INTEGRATION). Used in the storage integration role trust policy."
  type        = string
  default     = null
}

variable "resource_prefix" {
  description = "The prefix to use for the resources."
  type        = string
  default     = "benchmark-dms"
}
