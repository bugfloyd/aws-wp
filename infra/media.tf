# Per-site media buckets.
#
# WordPress keeps writing uploads to the shared file system exactly as it always
# has - no plugin, no stream wrapper, nothing installed inside WordPress. A timer
# mirrors them here, and CloudFront prefers this bucket over the instance for
# anything under /wp-content/uploads/.
#
# The mirror is for *serving*, not for durability: the file system remains the
# source of truth, so an instance can be replaced mid-upload and lose nothing.
# That is what lets the sync interval be a performance knob rather than a data
# loss window.
#
# One bucket per site per environment. A staging site pointed at a production
# bucket would cheerfully delete production media on its first sync.

locals {
  # Derived rather than read back off the resource, so the bootstrap template can
  # be rendered - and its shell syntax checked - before the buckets exist.
  media_bucket_names = {
    for d in keys(var.domains) :
    d => "${var.stack_name}-${replace(d, ".", "-")}-media"
  }
}

resource "aws_s3_bucket" "media" {
  for_each = var.domains

  bucket = local.media_bucket_names[each.key]

  tags = {
    Name       = "WebsitesMedia-${each.key}"
    Website    = each.key
    CostCenter = "Bugfloyd/Websites/Media"
  }
}

resource "aws_s3_bucket_public_access_block" "media" {
  for_each = aws_s3_bucket.media

  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "media" {
  for_each = aws_s3_bucket.media

  bucket = each.value.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "media" {
  for_each = aws_s3_bucket.media

  bucket = each.value.id

  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# One Origin Access Control shared by every media bucket. It carries no
# bucket-specific state - the scoping is done by each bucket's own policy, which
# names the single distribution allowed to read it.
resource "aws_cloudfront_origin_access_control" "media" {
  name                              = "${var.stack_name}-media${var.edge_policy_suffix}"
  description                       = "CloudFront access to the per-site media buckets"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Read access for exactly one distribution, and nothing else.
#
# Note this grants s3:GetObject and deliberately not s3:ListBucket. That is what
# makes a missing key answer 403 rather than 404 - S3 will not confirm whether an
# object exists to a caller that cannot list - and it is why the origin group's
# failover criteria have to include 403. Proven by experiment: with 403 removed
# from the criteria, a not-yet-synced upload returns AccessDenied instead of
# falling back to the instance.
data "aws_iam_policy_document" "media" {
  for_each = var.enable_edge ? aws_s3_bucket.media : {}

  statement {
    sid       = "AllowCloudFrontRead"
    effect    = "Allow"
    actions   = ["s3:GetObject"]
    resources = ["${each.value.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [module.websites_cert_cloudfront_dns[each.key].distribution_arn]
    }
  }
}

resource "aws_s3_bucket_policy" "media" {
  for_each = var.enable_edge ? aws_s3_bucket.media : {}

  bucket = each.value.id
  policy = data.aws_iam_policy_document.media[each.key].json
}

# The instance writes the mirror. Scoped to the media buckets only - the
# instance role already reaches the config bucket, and widening it to "every
# bucket" would put the Terraform state bucket in reach of a compromised
# web server.
resource "aws_iam_policy" "media_sync" {
  name        = "${var.stack_name}-media-sync"
  description = "Mirror wp-content/uploads to the per-site media buckets"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ListMediaBuckets"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [for b in aws_s3_bucket.media : b.arn]
      },
      {
        Sid      = "WriteMedia"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"]
        Resource = [for b in aws_s3_bucket.media : "${b.arn}/*"]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "media_sync" {
  role       = aws_iam_role.instance_role.name
  policy_arn = aws_iam_policy.media_sync.arn
}

output "media_buckets" {
  description = "Per-site media buckets the uploads directory is mirrored into"
  value       = { for k, b in aws_s3_bucket.media : k => b.bucket }
}
