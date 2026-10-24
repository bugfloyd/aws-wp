output "configuration_set_name" {
  description = "Configuration set every identity sends through by default"
  value       = aws_sesv2_configuration_set.sites.configuration_set_name
}

output "events_topic_arn" {
  description = "SNS topic that receives bounce, complaint and reject events"
  value       = aws_sns_topic.events.arn
}

output "dns_records" {
  description = "Per domain whose DNS is hosted elsewhere, the records to create there. SES gives up on DKIM it cannot find within 72 hours"
  value = {
    for d, s in var.domains : d => concat(
      [
        for t in aws_sesv2_email_identity.site[d].dkim_signing_attributes[0].tokens : {
          name    = "${t}._domainkey.${d}"
          type    = "CNAME"
          value   = "${t}.dkim.amazonses.com"
          purpose = "SES DKIM signing key"
        }
      ],
      [
        {
          name    = "${var.mail_from_subdomain}.${d}"
          type    = "MX"
          value   = local.mail_from_mx
          purpose = "SES MAIL FROM, the envelope sender SPF checks"
        },
        {
          name    = "${var.mail_from_subdomain}.${d}"
          type    = "TXT"
          value   = local.mail_from_spf
          purpose = "SPF for the MAIL FROM subdomain"
        },
      ],
      s.dmarc_record == null ? [] : [
        {
          name    = "_dmarc.${d}"
          type    = "TXT"
          value   = s.dmarc_record
          purpose = "DMARC: a policy for all mail sent as the domain, so only with its owner's agreement"
        }
      ],
    ) if s.zone_id == null
  }
}
