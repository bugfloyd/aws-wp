terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      version               = "~> 6.0"
      configuration_aliases = [aws.us_east_1]
    }
  }
}

locals {
  tags = {
    Website = var.domain
  }

  # AWS managed "CachingDisabled": every TTL 0.
  caching_disabled = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"

  hostnames = {
    for h in concat([var.domain], var.aliases) :
    (h == var.domain ? "@" : trimsuffix(h, ".${var.domain}")) => h
  }
}

# From when every site was an apex with a www alias, and everything here existed
# unconditionally.
moved {
  from = aws_cloudfront_distribution.cloudfront
  to   = aws_cloudfront_distribution.cloudfront[0]
}

moved {
  from = aws_acm_certificate_validation.cert_validation
  to   = aws_acm_certificate_validation.cert_validation[0]
}

moved {
  from = aws_route53_record.main_dns_record
  to   = aws_route53_record.hostname["@"]
}

moved {
  from = aws_route53_record.www_dns_record
  to   = aws_route53_record.hostname["www"]
}
