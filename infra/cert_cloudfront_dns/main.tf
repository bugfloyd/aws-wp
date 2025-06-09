terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 5.88"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

locals {
  tags = {
    Website = var.domain
  }
}
