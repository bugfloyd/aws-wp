# The bucket this configuration manages is also where it keeps its own state.
#
# That is circular only at creation: on a new account, run this once with local
# state, then `terraform init -migrate-state` to move the state into the bucket
# it just made. Afterwards it is an ordinary configuration, and the bucket is
# described by code rather than remembered by whoever created it.
terraform {
  backend "s3" {
    key          = "aws-wp/state-backend/terraform.tfstate"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  required_version = ">= 1.10"
}
