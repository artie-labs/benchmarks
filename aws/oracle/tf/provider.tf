provider "aws" {
  region  = var.region
  profile = var.aws_profile

  default_tags {
    tags = {
      Purpose = var.resource_prefix
    }
  }
}

terraform {
  backend "local" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    random = {
      source = "hashicorp/random"
    }
  }
}
