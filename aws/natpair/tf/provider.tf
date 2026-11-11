provider "aws" {
  region  = var.region
  profile = var.aws_profile

  # Every resource, including the natpair module's, carries bench=natpair, so a teardown check can find leftovers.
  default_tags {
    tags = {
      bench = "natpair"
    }
  }
}

terraform {
  required_version = ">= 1.6.0"
  backend "local" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}
