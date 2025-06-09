resource "aws_cloudfront_distribution" "cloudfront" {
  comment = "CloudFront for ${var.domain}"

  aliases = [
    var.domain,
    "www.${var.domain}"
  ]

  enabled         = true
  http_version    = "http2"
  is_ipv6_enabled = false

  origin {
    domain_name        = var.lb_dns_name
    origin_id          = "ALBOrigin"
    connection_timeout = 10

    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 60
      origin_read_timeout      = 30
    }

    custom_header {
      name  = "X-CloudFront-Auth"
      value = random_uuid.unique_id.result
    }
  }

  default_cache_behavior {
    target_origin_id       = "ALBOrigin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id          = var.disable_cache ? "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" : aws_cloudfront_cache_policy.cache_policy.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.origin_request_policy.id

    compress = true
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert_validation.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  logging_config {
    bucket          = "${var.logging_bucket}.s3.amazonaws.com"
    prefix          = "${var.domain}/web/"
    include_cookies = true
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  tags = merge(local.tags, {
    Name       = "${var.domain}-CloudFrontDistribution"
    CostCenter = "Bugfloyd/Websites/CloudFront"
  })
}

resource "aws_cloudfront_cache_policy" "cache_policy" {
  name = "${replace(var.domain, ".", "_")}-cache-policy"

  default_ttl = 86400
  max_ttl     = 31536000
  min_ttl     = 0

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Host", "Options"]
      }
    }

    query_strings_config {
      query_string_behavior = "all"
    }

    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

resource "aws_cloudfront_origin_request_policy" "origin_request_policy" {
  name = "${replace(var.domain, ".", "_")}-origin-policy"

  cookies_config {
    cookie_behavior = "all"
  }

  headers_config {
    header_behavior = "allViewerAndWhitelistCloudFront"
    headers {
      items = [
        "CloudFront-Forwarded-Proto",
        "CloudFront-Viewer-Http-Version",
        "CloudFront-Is-Android-Viewer",
        "CloudFront-Is-Desktop-Viewer",
        "CloudFront-Is-IOS-Viewer",
        "CloudFront-Is-Mobile-Viewer",
        "CloudFront-Is-SmartTV-Viewer",
        "CloudFront-Is-Tablet-Viewer",
        "CloudFront-Viewer-Address",
        "CloudFront-Viewer-ASN",
        "CloudFront-Viewer-City",
        "CloudFront-Viewer-Country",
        "CloudFront-Viewer-Country-Name",
        "CloudFront-Viewer-Country-Region",
        "CloudFront-Viewer-Country-Region-Name",
        "CloudFront-Viewer-Http-Version",
        "CloudFront-Viewer-Latitude",
        "CloudFront-Viewer-Longitude",
        "CloudFront-Viewer-Metro-Code",
        "CloudFront-Viewer-Postal-Code",
        "CloudFront-Viewer-Time-Zone",
        "CloudFront-Viewer-TLS",
      ]
    }
  }

  query_strings_config {
    query_string_behavior = "all"
  }
}

resource "aws_route53_record" "main_dns_record" {
  zone_id = var.hosted_zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cloudfront.domain_name
    zone_id                = "Z2FDTNDATAQYW2" # CloudFront's Hosted Zone ID
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "www_dns_record" {
  zone_id = var.hosted_zone_id
  name    = "www.${var.domain}"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.cloudfront.domain_name
    zone_id                = "Z2FDTNDATAQYW2" # CloudFront's Hosted Zone ID
    evaluate_target_health = false
  }
}

resource "random_uuid" "unique_id" {}
