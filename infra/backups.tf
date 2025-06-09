provider "aws" {
  alias  = "backups"
  region = var.aws_region_backup
}

resource "aws_s3_bucket" "backups_bucket" {
  provider = aws.backups
  bucket   = var.backups_bucket_name

  tags = {
    Name = "BugfloydBackupsBucket"
  }
}

resource "aws_s3_bucket_versioning" "backups_bucket_versioning" {
  provider = aws.backups
  bucket   = aws_s3_bucket.backups_bucket.id

  versioning_configuration {
    status = "Suspended"
  }
}

# - Delete objects after 730 days (2 years)
resource "aws_s3_bucket_lifecycle_configuration" "backup_bucket_lifecycle" {
  provider = aws.backups
  bucket   = aws_s3_bucket.backups_bucket.id

  rule {
    id     = "backup-expiration"
    status = "Enabled"

    # Apply to all objects in the bucket
    filter {}

    expiration {
      days = 730
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}


locals {
  backup_config = templatefile("${path.module}/templates/backup-config.conf.tpl", {
    s3_backup_bucket  = aws_s3_bucket.backups_bucket.id
    s3_backup_dir     = var.s3_backup_dir
    aws_region_backup = var.aws_region_backup
  })
}
