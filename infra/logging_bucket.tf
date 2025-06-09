resource "aws_s3_bucket" "cloudfront_logging_bucket" {
  bucket = var.cloudfront_logging_bucket_name

  tags = {
    Name       = "WebsitesCloudFrontLogsBucket"
    CostCenter = "Bugfloyd/Websites/CloudFront"
  }
}

# Bucket Ownership Controls
resource "aws_s3_bucket_ownership_controls" "ownership_controls" {
  bucket = aws_s3_bucket.cloudfront_logging_bucket.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Set ACL for LogDeliveryWrite
resource "aws_s3_bucket_acl" "logging_bucket_acl" {
  bucket     = aws_s3_bucket.cloudfront_logging_bucket.id
  acl        = "log-delivery-write"
  depends_on = [aws_s3_bucket.cloudfront_logging_bucket]
}

# Disable Bucket Versioning
resource "aws_s3_bucket_versioning" "logging_bucket_versioning" {
  bucket = aws_s3_bucket.cloudfront_logging_bucket.id

  versioning_configuration {
    status = "Suspended"
  }
}

# Lifecycle Policy: 
# - Delete objects after 1825 days (5 years)
resource "aws_s3_bucket_lifecycle_configuration" "logging_bucket_lifecycle" {
  bucket = aws_s3_bucket.cloudfront_logging_bucket.id

  rule {
    id     = "log-expiration"
    status = "Enabled"

    # Apply to all objects in the bucket
    filter {}

    expiration {
      days = 1825
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
