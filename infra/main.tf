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

module "websites_cert_cloudfront_dns" {
  source = "./cert_cloudfront_dns"

  for_each = var.domains

  domain              = each.key
  hosted_zone_id      = each.value
  logging_bucket      = aws_s3_bucket.cloudfront_logging_bucket.id
  instance_public_dns = aws_eip.webserver.public_dns
  origin_http_port    = var.webserver_http_port
  # Cache at the edge, as production does: a 24 hour default TTL on a custom
  # policy. WordPress sends no-cache on admin and logged-in responses, so those
  # still reach the origin. Disabling the cache would send every request to a
  # single small instance, which is the opposite of the point.
  disable_cache = false

  providers = {
    aws.us_east_1 = aws.us_east_1
  }
}

