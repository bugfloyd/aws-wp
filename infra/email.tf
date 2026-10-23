# Outbound mail through SES.
#
# Each site's domain becomes an SES identity: DKIM keys, a MAIL FROM subdomain
# and a DMARC record in its zone, so mail sent as the site passes SPF, DKIM and
# DMARC. Bounce, complaint and reject events go to alert_email.
#
# A new account starts in the SES sandbox, which delivers only to verified
# addresses, up to 200 a day. Leaving it is a request to AWS (README → Email),
# made once per account and Region. Nothing here sends mail by itself:
# WordPress still has to be pointed at SES.
module "email" {
  source = "./email"
  count  = var.enable_email ? 1 : 0

  name                = var.stack_name
  domains             = var.domains
  mail_from_subdomain = var.email_mail_from_subdomain
  dmarc_record        = var.email_dmarc_record
}

# Needs the same one-time confirmation click as the alarms' subscription.
resource "aws_sns_topic_subscription" "email_events" {
  count = var.enable_email ? 1 : 0

  topic_arn = module.email[0].events_topic_arn
  protocol  = "email"
  endpoint  = var.alert_email
}

output "email_configuration_set" {
  description = "SES configuration set every site's identity sends through"
  value       = one(module.email[*].configuration_set_name)
}

output "email_events_topic_arn" {
  description = "SNS topic for SES bounce, complaint and reject events"
  value       = one(module.email[*].events_topic_arn)
}
