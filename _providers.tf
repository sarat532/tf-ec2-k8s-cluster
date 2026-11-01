terraform {
  required_version = "~> 1.17.1"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.71.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.7.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}