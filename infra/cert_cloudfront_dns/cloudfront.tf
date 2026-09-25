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
    # A per-site name rather than the instance's AWS hostname. On paths that do
    # not forward the viewer's Host header, this name *is* the Host header the
    # origin sees, and it has to identify the site. See the origin record below.
    domain_name        = aws_route53_record.origin.fqdn
    origin_id          = "EC2Origin"
    connection_timeout = 10

    # Plain HTTP to the origin. CloudFront terminates TLS with an ACM
    # certificate, so the instance holds no certificate and has nothing to
    # renew - which is the third kind of state this stage removes, after files
    # and the database. The origin is protected twice: a security group locked
    # to CloudFront's prefix list, and the secret header below, because that
    # prefix list admits every CloudFront distribution, not only this one.
    custom_origin_config {
      http_port              = var.origin_http_port
      https_port             = 443
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]

      # Shorter than OpenLiteSpeed's keepAliveTimeout (75 s in
      # templates/httpd_config.conf.tftpl), so CloudFront always drops an idle
      # connection before the origin does and never sends a request down one
      # that is closing. Keep the two in that order.
      origin_keepalive_timeout = 60

      # Long enough to survive a WordPress admin action that rewrites files on
      # shared storage. A plugin update deletes the old directory and unpacks the
      # new one file by file, each a round trip over NFS - a 5,872-file install
      # takes about 39 seconds on FSx. At the 30-second default a large update
      # surfaces as a CloudFront 504 with no clue as to why.
      origin_read_timeout = var.origin_read_timeout
    }

    # Custom headers belong to the origin, so the media behavior's fallback to
    # the instance carries it too. CloudFront overwrites any copy a viewer sends.
    custom_header {
      name  = "X-Origin-Verify"
      value = var.origin_secret
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

  # Pages. Shared cache for anonymous visitors; the viewer request function
  # takes anyone with a personal cookie out of it (see edge_cache.tf).
  default_cache_behavior {
    target_origin_id       = "EC2Origin"
    viewer_protocol_policy = "redirect-to-https"

    allowed_methods = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]

    # Not OPTIONS. A CORS preflight's answer depends on the Origin and
    # Access-Control-Request-* headers, which are not in the cache key, so one
    # cached answer would be replayed to every other origin asking.
    cached_methods = ["GET", "HEAD"]

    cache_policy_id          = var.disable_cache ? local.caching_disabled : var.pages_cache_policy_id
    origin_request_policy_id = var.origin_request_policy_id

    compress = true

    function_association {
      event_type   = "viewer-request"
      function_arn = var.viewer_request_function_arn
    }

    function_association {
      event_type   = "viewer-response"
      function_arn = var.viewer_response_function_arn
    }
  }

  # Uploads come from the bucket when it has them, and from the instance when it
  # does not. Everything else - PHP, admin, generated CSS under
  # wp-content/uploads that the mirror deliberately does not cover - falls
  # through to the default behavior and the instance.
  ordered_cache_behavior {
    path_pattern           = "/wp-content/uploads/20??/*"
    target_origin_id       = "MediaGroup"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true

    # Only WordPress's own media, which lives in year/month folders. It is
    # immutable in practice - WordPress writes a new filename rather than editing
    # one in place - so CachingOptimized suits it, and that policy ignores query
    # strings.
    #
    # Which is exactly why the rest of uploads must not come through here.
    # Plugins also write under wp-content/uploads, and some regenerate a file
    # under the same name and bust caches with a query string: Elementor rewrites
    # elementor/css/post-6.css and links it as post-6.css?ver=<timestamp>. Under
    # this policy the new version would share the old one's cache entry, and S3
    # would hold the stale copy until the next sync. Routed through the default
    # behavior instead, those files come fresh from the file system with query
    # strings in the cache key - and nothing a plugin drops into uploads becomes
    # reachable from a bucket.
    cache_policy_id = "658327ea-f89d-4fab-a63d-7e88639e58f6"
  }

  # Never cached, whatever the response headers or cookies say. WordPress already
  # sends no-cache from most of these, but a plugin that forgets to cannot turn a
  # dashboard, a login form or an API answer into a shared page.
  #
  # The admin screens, admin-ajax.php included.
  ordered_cache_behavior {
    path_pattern             = "/wp-admin/*"
    target_origin_id         = "EC2Origin"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = local.caching_disabled
    origin_request_policy_id = var.origin_request_policy_id
    compress                 = true

    function_association {
      event_type   = "viewer-response"
      function_arn = var.viewer_response_function_arn
    }
  }

  # Every PHP file named wp-*: login, comment posting, signup, activation - and
  # wp-cron.php, which the viewer request function refuses outright. "*" spans
  # slashes, so this also catches PHP endpoints under wp-content and wp-includes.
  ordered_cache_behavior {
    path_pattern             = "/wp-*.php"
    target_origin_id         = "EC2Origin"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = local.caching_disabled
    origin_request_policy_id = var.origin_request_policy_id
    compress                 = true

    function_association {
      event_type   = "viewer-request"
      function_arn = var.viewer_request_function_arn
    }

    function_association {
      event_type   = "viewer-response"
      function_arn = var.viewer_response_function_arn
    }
  }

  # The REST API. Anonymous answers can differ per visitor in ways WordPress
  # does not mark, and stale data breaks the editors and forms that call it.
  ordered_cache_behavior {
    path_pattern             = "/wp-json/*"
    target_origin_id         = "EC2Origin"
    viewer_protocol_policy   = "redirect-to-https"
    allowed_methods          = ["HEAD", "DELETE", "POST", "GET", "OPTIONS", "PUT", "PATCH"]
    cached_methods           = ["GET", "HEAD"]
    cache_policy_id          = local.caching_disabled
    origin_request_policy_id = var.origin_request_policy_id
    compress                 = true

    function_association {
      event_type   = "viewer-response"
      function_arn = var.viewer_response_function_arn
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.cert_validation.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }

  # No cookies in the logs. CloudFront logs every cookie a viewer sends,
  # whatever the cache behavior forwards: that includes WordPress's
  # logged-in and auth cookies, which would sit in the bucket for the five
  # years its lifecycle keeps logs, usable by anyone who can read it until the
  # session ends. Nothing here reads them.
  logging_config {
    bucket          = "${var.logging_bucket}.s3.amazonaws.com"
    prefix          = "${var.domain}/web/"
    include_cookies = false
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


# The name CloudFront reaches the origin by, one per site.
#
# Every path through the default behavior forwards the viewer's Host header, so
# there the origin's own name is only used to find the instance. The media path
# is different: it cannot forward Host, because its primary origin is S3 and S3
# reads Host to decide which bucket a request is for. When that path fails over to
# the instance, the request arrives with this name as its Host - so the name has to
# say which site it is for.
#
# Pointing every site at the instance's AWS hostname looked equivalent and was
# not: OpenLiteSpeed matched none of them and served the catch-all site, so a
# not-yet-mirrored upload on one site returned another site's 404 page. A
# single-site stack cannot show this, because its catch-all is the right site.
#
# Publicly resolvable, and harmless: the instance only accepts port 80 from
# CloudFront's managed prefix list.
resource "aws_route53_record" "origin" {
  zone_id = var.hosted_zone_id
  name    = "origin.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [var.instance_public_ip]

  # A replacement stack claims the same name while the old one still holds it.
  allow_overwrite = true
}
