terraform {
  backend "s3" {
    key     = "hosted-zones-state/terraform.tfstate"
    encrypt = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.88"
    }
  }

  required_version = ">= 1.10"
}
