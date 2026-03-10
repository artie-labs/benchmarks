provider "aws" {
  region  = var.region
  profile = var.aws_profile
}

terraform {
  backend "local" {}
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}
