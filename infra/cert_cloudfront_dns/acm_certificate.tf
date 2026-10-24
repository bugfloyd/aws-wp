resource "aws_acm_certificate" "cloudfront_cert" {
  provider          = aws.us_east_1
  domain_name       = var.domain
  validation_method = "DNS"

  subject_alternative_names = var.aliases

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.tags, {
    Name       = "${var.domain}-CloudFrontACMCertificate"
    CostCenter = "Bugfloyd/Websites/CloudFront"
  })
}

# Only into a zone of ours. For DNS hosted elsewhere the same records are in
# dns_records, and someone creates them there.
resource "aws_route53_record" "cert_validation" {
  for_each = var.hosted_zone_id == null ? {} : {
    for dvo in aws_acm_certificate.cloudfront_cert.domain_validation_options :
    dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60

  # A second certificate for a domain already certified in this account gets the
  # same validation record name and value. Without this, standing a replacement
  # stack alongside the current one fails with "record set already exists".
  allow_overwrite = true
}

# Waits for ACM to issue the certificate, which it does once it can resolve the
# validation records. For DNS hosted elsewhere that wait only starts at dns_ready:
# before it, nothing would arrive and the apply would hang until it timed out.
resource "aws_acm_certificate_validation" "cert_validation" {
  count = var.dns_ready ? 1 : 0

  provider                = aws.us_east_1
  certificate_arn         = aws_acm_certificate.cloudfront_cert.arn
  validation_record_fqdns = var.hosted_zone_id == null ? null : [for record in aws_route53_record.cert_validation : record.fqdn]
}
