output "distribution_arn" {
  description = "ARN of the distribution, so the media bucket policy can name it. null until it is built"
  value       = one(aws_cloudfront_distribution.cloudfront[*].arn)
}

output "distribution_id" {
  description = "Distribution id. null until it is built"
  value       = one(aws_cloudfront_distribution.cloudfront[*].id)
}

output "dns_records" {
  description = "For DNS hosted elsewhere, the records to create there: the certificate's validation records, then the site's hostnames once the distribution exists. Empty with a hosted zone, where they are written here"
  value = var.hosted_zone_id != null ? [] : concat(
    [
      for dvo in aws_acm_certificate.cloudfront_cert.domain_validation_options : {
        name    = dvo.resource_record_name
        type    = dvo.resource_record_type
        value   = dvo.resource_record_value
        purpose = "Certificate validation for ${dvo.domain_name}. Keep it: renewals use it"
      }
    ],
    [
      for h in concat([var.domain], var.aliases) : {
        name    = h
        type    = "CNAME"
        value   = one(aws_cloudfront_distribution.cloudfront[*].domain_name)
        purpose = "The site. At a zone apex, where a CNAME is not allowed, an ALIAS, ANAME or flattened CNAME; in Route 53, an alias A record to this distribution"
      } if var.dns_ready
    ],
  )
}
