# Rendered OpenLiteSpeed configuration, delivered out of band.
#
# These started out embedded in the launch template's user data, which EC2 caps
# at 16 KB. The three configs plus the bootstrap script came to 16.7 KB with a
# single domain, and httpd_config grows with every domain added - so inlining
# was never going to survive the multi-site case.
#
# The bootstrap fetches them at boot instead. A hash of their contents is
# stamped into the user data, so changing a config still produces a new launch
# template version and a rolling instance refresh: the instances stay immutable.

resource "aws_s3_bucket" "config" {
  bucket = var.config_bucket_name

  tags = {
    Name       = "WebsitesConfigBucket"
    CostCenter = "Bugfloyd/Websites/Instance"
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_object" "httpd_config" {
  bucket       = aws_s3_bucket.config.id
  key          = "ols/httpd_config.conf"
  content      = local.httpd_config
  content_type = "text/plain"
  etag         = md5(local.httpd_config)
}

resource "aws_s3_object" "vhost_config" {
  bucket       = aws_s3_bucket.config.id
  key          = "ols/vhconf.conf"
  content      = local.vhost_config
  content_type = "text/plain"
  etag         = md5(local.vhost_config)
}

resource "aws_s3_object" "admin_config" {
  bucket       = aws_s3_bucket.config.id
  key          = "ols/admin_config.conf"
  content      = local.admin_config
  content_type = "text/plain"
  etag         = md5(local.admin_config)
}
