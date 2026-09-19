provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Owner   = "Bugfloyd"
      Service = "Bugfloyd/Websites"
    }
  }
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1" # ACM for CloudFront must be in us-east-1
}

# The edge tier is separable from the server.
#
# A CloudFront alternate domain name can belong to only one distribution at a
# time, account-wide, so a replacement stack cannot claim a live domain while
# the existing one holds it. Building with enable_edge = false stands up the
# server, its storage and its database - and lets a migration restore and verify
# real data - without touching DNS or certificates. Flip it to true at cutover.
# A shared secret CloudFront adds to every request it sends to the instance.
#
# The security group only proves a request came from CloudFront, and every
# CloudFront distribution in AWS draws from the same prefix list - anyone can
# point a distribution of their own at origin.<domain> and serve the sites
# through it. This header proves the request came from one of this stack's
# distributions. OpenLiteSpeed refuses anything without it, except requests the
# instance makes to itself.
#
# Alphanumeric, so it can sit unescaped inside a rewrite condition.
resource "random_password" "origin_secret" {
  length  = 40
  special = false
}

module "websites_cert_cloudfront_dns" {
  source = "./cert_cloudfront_dns"

  for_each = var.enable_edge ? var.domains : {}

  domain             = each.key
  hosted_zone_id     = each.value
  logging_bucket     = aws_s3_bucket.cloudfront_logging_bucket.id
  instance_public_ip = aws_eip.webserver.public_ip
  origin_http_port   = var.webserver_http_port
  # Cache at the edge: a 24 hour default TTL on a custom policy. WordPress sends no-cache on admin and logged-in responses, so those
  # still reach the origin. Disabling the cache would send every request to a
  # single small instance, which is the opposite of the point.
  disable_cache       = false
  origin_read_timeout = var.origin_read_timeout

  media_bucket_regional_domain_name = aws_s3_bucket.media[each.key].bucket_regional_domain_name
  media_oac_id                      = aws_cloudfront_origin_access_control.media.id
  policy_suffix                     = var.edge_policy_suffix
  origin_secret                     = random_password.origin_secret.result

  providers = {
    aws.us_east_1 = aws.us_east_1
  }
}

