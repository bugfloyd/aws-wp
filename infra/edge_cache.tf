# What CloudFront may cache, and for whom.
#
# Four layers, each covering what the one before cannot:
#
# 1. The viewer request function gives every request that carries a personal
#    cookie - logged in, a commenter's saved details, an unlocked password-
#    protected post, a shop cart or session - a cache key no other request will
#    ever have. Such a request is never served from the cache, and its response
#    is never served to anyone else. Static files are exempt: they are never
#    personalised, so logged-in users still get them cached.
# 2. Paths that are never cached whatever the headers or cookies say:
#    /wp-admin/*, /wp-*.php and /wp-json/* (see the edge module).
# 3. The origin guard (templates/edge_cache.php.tftpl) marks any response that
#    sets a cookie uncacheable, and gives public pages an explicit, short TTL
#    with stale-while-revalidate and stale-if-error.
# 4. WordPress's own no-cache headers for logged-in pages, password-protected
#    posts and 404s, which CloudFront honours because the minimum TTL is 0.
#
# The policies and functions are shared by every distribution rather than made
# per site. An account may hold 20 custom cache policies, and one per site
# would cap the platform below that.

locals {
  viewer_request_code = templatefile("${path.module}/templates/viewer_request.js.tftpl", {
    bypass_cookie_prefixes = var.cache_bypass_cookie_prefixes
    blocked_files          = [for f in var.edge_blocked_files : lower(f)]
  })

  edge_cache_guard = templatefile("${path.module}/templates/edge_cache.php.tftpl", {
    ttl = var.page_cache_ttl
    swr = var.page_stale_while_revalidate
    sie = var.page_stale_if_error
    # Only then can every request that reaches PHP from outside be trusted to
    # carry CloudFront's own CloudFront-Viewer-Address.
    trust_viewer_address = var.enable_edge && var.enforce_origin_secret
  })
}

resource "aws_cloudfront_function" "viewer_request" {
  name    = "${var.stack_name}-viewer-request${var.edge_policy_suffix}"
  runtime = "cloudfront-js-2.0"
  comment = "Cache key for personal requests; blocks public cron and XML-RPC"
  publish = true
  code    = local.viewer_request_code
}

resource "aws_cloudfront_function" "viewer_response" {
  name    = "${var.stack_name}-viewer-response${var.edge_policy_suffix}"
  runtime = "cloudfront-js-2.0"
  comment = "Tells browsers no-cache for pages CloudFront keeps with stale directives"
  publish = true
  code    = file("${path.module}/templates/viewer_response.js")
}

# What browsers are told about year-folder media: a lifetime when the origin
# gave none, on successful responses only (see the template).
resource "aws_cloudfront_function" "media_response" {
  name    = "${var.stack_name}-media-response${var.edge_policy_suffix}"
  runtime = "cloudfront-js-2.0"
  comment = "Browser lifetime for year-folder media when the origin sends none"
  publish = true
  code = templatefile("${path.module}/templates/media_response.js.tftpl", {
    ttl = var.media_browser_ttl
  })
}

# Pages and everything else on the default behavior.
#
# The minimum TTL of 0 is what makes CloudFront honour no-cache, no-store and
# private from the origin. The default TTL only applies to responses without a
# Cache-Control, which after the origin guard means static files OpenLiteSpeed
# does not give an expiry, such as PDFs; it matches the page TTL.
resource "aws_cloudfront_cache_policy" "pages" {
  name        = "${var.stack_name}-pages${var.edge_policy_suffix}"
  comment     = "WordPress pages: Host, personal-request marker and non-tracking query strings in the key"
  min_ttl     = 0
  default_ttl = var.page_cache_ttl
  max_ttl     = 31536000

  parameters_in_cache_key_and_forwarded_to_origin {
    cookies_config {
      cookie_behavior = "none"
    }

    headers_config {
      header_behavior = "whitelist"
      headers {
        items = ["Host", "X-Wp-Cache-Bypass"]
      }
    }

    # Tracking parameters are left out of the key, so one page with twenty
    # campaign links is one cached copy, not twenty. They still reach WordPress:
    # the origin request policy forwards every query string.
    query_strings_config {
      query_string_behavior = length(var.cache_ignored_query_strings) > 0 ? "allExcept" : "all"

      dynamic "query_strings" {
        for_each = length(var.cache_ignored_query_strings) > 0 ? [1] : []
        content {
          items = var.cache_ignored_query_strings
        }
      }
    }

    enable_accept_encoding_brotli = true
    enable_accept_encoding_gzip   = true
  }
}

# Everything WordPress needs from the viewer reaches the origin, whether or not
# it is part of the cache key.
resource "aws_cloudfront_origin_request_policy" "origin" {
  name    = "${var.stack_name}-origin${var.edge_policy_suffix}"
  comment = "All cookies, query strings and viewer headers to the WordPress origin"

  cookies_config {
    cookie_behavior = "all"
  }

  headers_config {
    header_behavior = "allViewerAndWhitelistCloudFront"
    headers {
      items = [
        "CloudFront-Forwarded-Proto",
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
