variable "region" {
  description = "The region to deploy the bench to."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "The profile to use for the AWS CLI, such as customer-sandbox."
  type        = string
  default     = null
}

variable "availability_zone" {
  description = "The zone for every subnet. Peering between VPCs in one zone carries no transfer charge."
  type        = string
  default     = "us-west-2a"
}

variable "name" {
  description = "Name prefix for the bench's resources. IAM names are global to the account, so it must be unique there."
  type        = string
  default     = "natpair-bench"
}

variable "nat_instance_type" {
  description = "Arm64 instance type for both NATs. Changing it on a running pair stops and starts each NAT: see the README."
  type        = string
  default     = "c7gn.medium"
}

variable "generator_instance_type" {
  description = "Instance type of the load generators in the worker subnet."
  type        = string
  default     = "c7gn.large"
}

variable "generator_count" {
  description = "How many load generators to run."
  type        = number
  default     = 2
}

variable "receiver_instance_type" {
  description = "Instance type of the receiver in the peered VPC. It runs the iperf3 servers and the job queue."
  type        = string
  default     = "c7gn.xlarge"
}

variable "natpair_release" {
  description = "natpair release tag the NATs install at first boot."
  type        = string
  default     = "v0.1.1"
}

variable "natpair_release_sha256" {
  description = "SHA-256 of the release's natpair_linux_arm64.tar.gz."
  type        = string
  default     = "68d771edf4fde30e5d5ec52736568c68f8222067c5caa5269820186ea8da48ab"
}

variable "natpair_release_url" {
  description = "Where the NATs download releases from. An s3:// prefix holding <tag>/natpair_linux_arm64.tar.gz serves a dev build, such as s3://<bench bucket>/natpair."
  type        = string
  default     = "https://github.com/artie-labs/natpair/releases/download"
}

variable "auto_stop_minutes" {
  description = "Generators and the receiver stop this many minutes after each boot, so a forgotten bench doesn't run for days."
  type        = number
  default     = 240
}

variable "igw_check" {
  description = "Let the receiver accept traffic from the shared Elastic IP, for a run with TARGET=public through the internet gateway. Such a run pays public data transfer, so leave it off otherwise."
  type        = bool
  default     = false
}

variable "pacing" {
  description = "natpair's pacing input, passed through. NATs read it at first boot. On a running NAT, `natpair pacing-off` and `pacing-on` switch it, which run.sh does with PACING=off|on."
  type = object({
    enabled          = optional(bool, false)
    start_mbps       = optional(number)
    start_kpps       = optional(number)
    poll_interval_ms = optional(number)
  })
  default = {}
}
