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
    domain_name        = var.instance_public_dns
    origin_id          = "EC2Origin"
    connection_timeout = 10

    # Plain HTTP to the origin. CloudFront terminates TLS with an ACM
    # certificate, so the instance holds no certificate and has nothing to
    # renew - which is the third kind of state this stage removes, after files
    # and the database. The origin is protected by a security group locked to
    # CloudFront's own prefix list rather than by a shared secret header.
    custom_origin_config {
      http_port                = var.origin_http_port
      https_port               = 443
      origin_protocol_policy   = "http-only"
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_keepalive_timeout = 60

      # Long enough to survive a WordPress admin action that rewrites files on
      # EFS. Creating small files over NFS runs at roughly 130/sec against
      # 21,000/sec on local disk, and a plugin update deletes the old directory
      # and unpacks the new one file by file - about 30 seconds for a 2,000-file
      # plugin like Yoast, before the download even starts. At the 30-second
      # default that surfaces as a CloudFront 504 with no clue as to why.
      origin_read_timeout = var.origin_read_timeout
    }
  }

  # The media bucket, and the group that prefers it.
  #
  # The instance is the fallback, not a peer: the file system is still the
  # source of truth and the mirror runs on a timer, so an upload made in the
  # last few minutes may not be here yet.
  origin {
    domain_name              = var.media_bucket_regional_domain_name
    origin_id                = "MediaOrigin"
    origin_access_control_id = var.media_oac_id

    # No custom_origin_config: an S3 origin with OAC is a native origin and
    # CloudFront signs the request.
  }

  origin_group {
    origin_id = "MediaGroup"

    # 403, not 404. The bucket policy grants s3:GetObject and not
    # s3:ListBucket, so S3 refuses to say whether a missing key exists and
    # answers AccessDenied. A criteria list of [404] reads perfectly sensibly
    # and never fails over at all - verified by removing 403 and watching an
    # unsynced object return AccessDenied instead of the instance's copy.
    failover_criteria {
      status_codes = [403, 404, 500, 502, 503, 504]
    }

    member {
      origin_id = "MediaOrigin"
    }

    member {
      origin_id = "EC2Origin"
    }
  }

  default_cache_behavior {
    target_origin_id       = "EC2Origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]
    cached_methods  = ["GET", "HEAD", "OPTIONS"]

    cache_policy_id          = var.disable_cache ? "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" : aws_cloudfront_cache_policy.cache_policy.id
    origin_request_policy_id = aws_cloudfront_origin_request_policy.origin_request_policy.id

    compress = true
  }

  # Uploads come from the bucket when it has them, and from the instance when it
  # does not. Everything else - PHP, admin, generated CSS under
  # wp-content/uploads that the mirror deliberately does not cover - falls
  # through to the default behavior and the instance.
  ordered_cache_behavior {
    path_pattern           = "/wp-content/uploads/*"
    target_origin_id       = "MediaGroup"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Media is immutable in practice: WordPress writes a new filename rather
    # than editing one in place. CachingOptimized is the managed policy for it.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
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
  name = "${replace(var.domain, ".", "_")}-cache-policy${var.policy_suffix}"

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
  name = "${replace(var.domain, ".", "_")}-origin-policy${var.policy_suffix}"

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

  # A cutover repoints an existing alias record at a different distribution.
  # Without this the apply fails because the record already exists.
  allow_overwrite = true
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

  # A cutover repoints an existing alias record at a different distribution.
  # Without this the apply fails because the record already exists.
  allow_overwrite = true
}

