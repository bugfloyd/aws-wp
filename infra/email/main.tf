terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  tags = {
    CostCenter = "Bugfloyd/Websites/Email"
  }

  # Easy DKIM issues three keys per domain. Keyed by domain and position, so the
  # plan knows every record before SES has issued the tokens that name them.
  dkim_records = {
    for pair in setproduct(keys(var.domains), range(3)) :
    "${pair[0]}/${pair[1]}" => { domain = pair[0], index = pair[1] }
  }
}

# Every identity sends through this set by default, so bounces, complaints and
# rejections are reported whichever plugin or relay sends the message.
resource "aws_sesv2_configuration_set" "sites" {
  configuration_set_name = var.name

  reputation_options {
    reputation_metrics_enabled = true
  }

  tags = merge(local.tags, { Name = "WebsitesEmailConfigurationSet" })
}

# A topic of its own rather than the alarms' topic: SES publishes only to a
# topic whose policy names it, and replacing the alarms' policy to add SES risks
# the one thing that topic must never do, which is go quiet.
resource "aws_sns_topic" "events" {
  name         = "${var.name}-email-events"
  display_name = "Websites email"

  tags = merge(local.tags, { Name = "WebsitesEmailEventsTopic" })
}

resource "aws_sns_topic_policy" "events" {
  arn = aws_sns_topic.events.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SesEventsFromThisConfigurationSet"
      Effect    = "Allow"
      Principal = { Service = "ses.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.events.arn
      Condition = {
        StringEquals = {
          "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          "AWS:SourceArn"     = aws_sesv2_configuration_set.sites.arn
        }
      }
    }]
  })
}

# Deliveries are left out: one message per sent email would bury the ones that
# need a person. The account-level suppression list stops repeat sends to an
# address that bounced or complained.
resource "aws_sesv2_configuration_set_event_destination" "events" {
  configuration_set_name = aws_sesv2_configuration_set.sites.configuration_set_name
  event_destination_name = "sns"

  event_destination {
    enabled              = true
    matching_event_types = ["BOUNCE", "COMPLAINT", "REJECT"]

    sns_destination {
      topic_arn = aws_sns_topic.events.arn
    }
  }

  depends_on = [aws_sns_topic_policy.events]
}

resource "aws_sesv2_email_identity" "site" {
  for_each = var.domains

  email_identity         = each.key
  configuration_set_name = aws_sesv2_configuration_set.sites.configuration_set_name

  dkim_signing_attributes {
    next_signing_key_length = "RSA_2048_BIT"
  }

  tags = merge(local.tags, { Name = "WebsitesEmailIdentity", Website = each.key })
}

resource "aws_route53_record" "dkim" {
  for_each = local.dkim_records

  zone_id = var.domains[each.value.domain]
  name    = "${aws_sesv2_email_identity.site[each.value.domain].dkim_signing_attributes[0].tokens[each.value.index]}._domainkey.${each.value.domain}"
  type    = "CNAME"
  ttl     = 1800
  records = ["${aws_sesv2_email_identity.site[each.value.domain].dkim_signing_attributes[0].tokens[each.value.index]}.dkim.amazonses.com"]
}

# The envelope sender. SPF checks this domain, not the visible From, so a
# subdomain with its own MX and SPF records aligns SPF for DMARC without
# touching the site's own SPF record or whatever receives its mail. If SES ever
# finds the MX missing, it falls back to its own domain: SPF no longer aligns,
# DKIM still does, and DMARC still passes.
resource "aws_sesv2_email_identity_mail_from_attributes" "site" {
  for_each = var.domains

  email_identity         = aws_sesv2_email_identity.site[each.key].email_identity
  mail_from_domain       = "${var.mail_from_subdomain}.${each.key}"
  behavior_on_mx_failure = "USE_DEFAULT_VALUE"
}

resource "aws_route53_record" "mail_from_mx" {
  for_each = var.domains

  zone_id = each.value
  name    = "${var.mail_from_subdomain}.${each.key}"
  type    = "MX"
  ttl     = 1800
  records = ["10 feedback-smtp.${data.aws_region.current.region}.amazonses.com"]
}

resource "aws_route53_record" "mail_from_spf" {
  for_each = var.domains

  zone_id = each.value
  name    = "${var.mail_from_subdomain}.${each.key}"
  type    = "TXT"
  ttl     = 1800
  records = ["v=spf1 include:amazonses.com ~all"]
}

resource "aws_route53_record" "dmarc" {
  for_each = var.dmarc_record == null ? {} : var.domains

  zone_id = each.value
  name    = "_dmarc.${each.key}"
  type    = "TXT"
  ttl     = 1800
  records = [var.dmarc_record]
}
