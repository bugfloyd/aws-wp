# The Terraform state buckets.
#
# Everything else in this repo keeps its state in one of these two, so they
# cannot live in the same configuration as the stacks themselves. They were
# created by a separate repo that has since been retired, which left the bucket
# holding production state described by nothing but a local file on one laptop.
#
# Versioning is the one setting that matters: state is rewritten in place on
# every apply, and a bad push or a corrupted upload is recoverable only from an
# earlier version. There is deliberately no lifecycle rule expiring those
# versions - they are the recovery path, and old ones can hold secrets that
# predate RDS-managed passwords, so they are purged deliberately, never on a
# schedule.
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner   = "Bugfloyd"
      Service = "Bugfloyd/Init"
    }
  }
}

provider "aws" {
  alias  = "zones"
  region = var.zones_state_bucket_region

  default_tags {
    tags = {
      Owner   = "Bugfloyd"
      Service = "Bugfloyd/Init"
    }
  }
}

resource "aws_s3_bucket" "infra_state" {
  bucket = var.infra_state_bucket

  # Losing this bucket loses the record of every resource in the account that
  # Terraform manages. Nothing here is worth destroying automatically.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "infra_state" {
  bucket = aws_s3_bucket.infra_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "infra_state" {
  bucket                  = aws_s3_bucket.infra_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "infra_state" {
  bucket = aws_s3_bucket.infra_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket" "zones_state" {
  provider = aws.zones
  bucket   = var.zones_state_bucket

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "zones_state" {
  provider = aws.zones
  bucket   = aws_s3_bucket.zones_state.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_public_access_block" "zones_state" {
  provider                = aws.zones
  bucket                  = aws_s3_bucket.zones_state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "zones_state" {
  provider = aws.zones
  bucket   = aws_s3_bucket.zones_state.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

output "infra_state_bucket" {
  description = "Bucket holding infra/ state"
  value       = aws_s3_bucket.infra_state.id
}

output "zones_state_bucket" {
  description = "Bucket holding hostedzones/ state"
  value       = aws_s3_bucket.zones_state.id
}
