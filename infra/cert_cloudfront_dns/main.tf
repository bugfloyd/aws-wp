terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

locals {
  tags = {
    Website = var.domain
  }

  # AWS managed "CachingDisabled": every TTL 0.
  caching_disabled = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
}
