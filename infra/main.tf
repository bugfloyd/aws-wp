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

# The edge tier is separable from the server.
#
# A CloudFront alternate domain name can belong to only one distribution at a
# time, account-wide, so a replacement stack cannot claim a live domain while
# the existing one holds it. Building with enable_edge = false stands up the
# server, its storage and its database - and lets a migration restore and verify
# real data - without touching DNS or certificates. Flip it to true at cutover.
module "websites_cert_cloudfront_dns" {
  source = "./cert_cloudfront_dns"

  for_each = var.enable_edge ? var.domains : {}

  domain             = each.key
  hosted_zone_id     = each.value
  logging_bucket     = aws_s3_bucket.cloudfront_logging_bucket.id
  instance_public_ip = aws_eip.webserver.public_ip
  origin_http_port   = var.webserver_http_port
  # Cache at the edge, on the rules in edge_cache.tf. Disabling it would send
  # every request to a single small instance, which is the opposite of the point.
  disable_cache       = false
  origin_read_timeout = var.origin_read_timeout

  media_bucket_regional_domain_name = aws_s3_bucket.media[each.key].bucket_regional_domain_name
  media_oac_id                      = aws_cloudfront_origin_access_control.media.id
  origin_secret                     = random_password.origin_secret.result

  pages_cache_policy_id        = aws_cloudfront_cache_policy.pages.id
  origin_request_policy_id     = aws_cloudfront_origin_request_policy.origin.id
  viewer_request_function_arn  = aws_cloudfront_function.viewer_request.arn
  viewer_response_function_arn = aws_cloudfront_function.viewer_response.arn

  providers = {
    aws.us_east_1 = aws.us_east_1
  }
}

