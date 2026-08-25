terraform {
  backend "s3" {
    # Namespaced to this project. "bugfloyd-state/" is bugfloyd-infra's own
    # production state key, so a generic name risks a stack adopting another
    # stack's resources the moment both point at the same bucket.
    key          = "aws-wp/infra/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.88"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }

  required_version = ">= 1.10"
}
